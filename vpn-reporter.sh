#!/bin/bash
# VPN Usage Reporter — runs every 2 minutes via cron
# Collects OpenVPN, Xray, SSH session data and POSTs to panel API
# Config loaded from /etc/.db-base

DB_BASE=/etc/.db-base
[ ! -f "$DB_BASE" ] && DB_BASE=/root/.db-base
[ ! -f "$DB_BASE" ] && exit 0

API_LINK=$(grep -oP "(?<=API_LINK=')[^']*" "$DB_BASE" 2>/dev/null | head -1)
API_KEY=$(grep -oP "(?<=API_KEY=')[^']*" "$DB_BASE" 2>/dev/null | head -1)
SERVER_IP=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')

[ -z "$API_LINK" ] || [ -z "$API_KEY" ] && exit 0

REPORT_URL="${API_LINK%/api/authentication}/api/usage/report.php"
TMP_FILE=/tmp/vpn_report_$$.json

connections=()

# ── 1. OpenVPN TCP/UDP ─────────────────────────────────────────────────────────
for STATUS_LOG in /var/log/openvpn/openvpn-status.log /tmp/openvpn-status.log; do
    [ ! -f "$STATUS_LOG" ] && continue
    in_client=0
    while IFS=',' read -r field1 field2 field3 field4 rest; do
        [ "$field1" = "CLIENT_LIST" ] && in_client=1 && continue
        [ "$in_client" = "0" ] && continue
        [ "$field1" = "ROUTING_TABLE" ] || [ "$field1" = "GLOBAL_STATS" ] && break
        USERNAME="$field1"
        CLIENT_IP="${field2%%:*}"
        VPN_IP="$field3"
        BYTES_RECV="$field4"
        BYTES_SENT=$(echo "$rest" | cut -d',' -f1)
        [ -z "$USERNAME" ] || [ "$USERNAME" = "Common Name" ] && continue
        # Detect protocol from log filename
        PROTO="openvpn_tcp"
        echo "$STATUS_LOG" | grep -qi "udp" && PROTO="openvpn_udp"
        connections+=("{\"username\":\"$USERNAME\",\"protocol\":\"$PROTO\",\"bytes_up\":${BYTES_SENT:-0},\"bytes_down\":${BYTES_RECV:-0},\"client_ip\":\"$CLIENT_IP\",\"status\":\"connected\"}")
    done < "$STATUS_LOG"
done

# ── 2. Xray stats (vmess, vless, trojan, shadowsocks) ─────────────────────────
XRAY_BIN=/usr/local/bin/xray
if [ -x "$XRAY_BIN" ] && ss -tlnp 2>/dev/null | grep -q ':62789'; then
    STATS_RAW=$($XRAY_BIN api statsquery --server=127.0.0.1:62789 --pattern "" 2>/dev/null)
    if [ -n "$STATS_RAW" ]; then
        # Parse: stat{name:"inbound>>>vmess-in>>>user>>>alice>>>traffic>>>uplink" value:12345}
        while IFS= read -r line; do
            NAME=$(echo "$line" | grep -oP '(?<=name:")[^"]+')
            VALUE=$(echo "$line" | grep -oP '(?<=value:)\d+')
            [ -z "$NAME" ] || [ -z "$VALUE" ] || [ "$VALUE" = "0" ] && continue

            # Extract user and direction from stat name
            # Format: inbound>>>PROTO-in>>>user>>>USERNAME>>>traffic>>>uplink|downlink
            USERNAME=$(echo "$NAME" | grep -oP '(?<=>>>user>>>)[^>]+')
            DIRECTION=$(echo "$NAME" | grep -oP '(?<=traffic>>>)\w+')
            INBOUND=$(echo "$NAME" | grep -oP 'inbound>>>\K[^>]+')

            [ -z "$USERNAME" ] && continue

            case "$INBOUND" in
                vmess-in|vmess-grpc-in)   PROTO="xray_vmess"  ;;
                vless-in|vless-grpc-in)   PROTO="xray_vless"  ;;
                trojan-in|trojan-grpc-in) PROTO="xray_trojan" ;;
                ss-in|ss-grpc-in)         PROTO="xray_ss"     ;;
                *)                         PROTO="xray_vmess"  ;;
            esac

            if [ "$DIRECTION" = "uplink" ]; then
                connections+=("{\"username\":\"$USERNAME\",\"protocol\":\"$PROTO\",\"bytes_up\":$VALUE,\"bytes_down\":0,\"client_ip\":\"\",\"status\":\"connected\"}")
            else
                connections+=("{\"username\":\"$USERNAME\",\"protocol\":\"$PROTO\",\"bytes_up\":0,\"bytes_down\":$VALUE,\"client_ip\":\"\",\"status\":\"connected\"}")
            fi
        done <<< "$STATS_RAW"
    fi
fi

# ── 3. SSH / Dropbear sessions ─────────────────────────────────────────────────
# Read connected SSH users from /var/run/sshd or 'who' output
while IFS= read -r line; do
    USERNAME=$(echo "$line" | awk '{print $1}')
    [[ "$USERNAME" =~ ^(root|nobody|daemon|www-data)$ ]] && continue
    [ -z "$USERNAME" ] && continue
    PROTO="ssh_ws"
    connections+=("{\"username\":\"$USERNAME\",\"protocol\":\"$PROTO\",\"bytes_up\":0,\"bytes_down\":0,\"client_ip\":\"\",\"status\":\"connected\"}")
done < <(who 2>/dev/null | grep -v "^root")

# ── Build JSON and POST ───────────────────────────────────────────────────────
if [ ${#connections[@]} -eq 0 ]; then
    # Send empty report so panel knows server is alive and updates online=0
    JSON="{\"server_ip\":\"$SERVER_IP\",\"timestamp\":$(date +%s),\"connections\":[]}"
else
    CONN_JSON=$(IFS=,; echo "[${connections[*]}]")
    JSON="{\"server_ip\":\"$SERVER_IP\",\"timestamp\":$(date +%s),\"connections\":$CONN_JSON}"
fi

RESPONSE=$(curl -s --max-time 15 \
    -X POST "$REPORT_URL" \
    -H "Authorization: Bearer $API_KEY" \
    -H "Content-Type: application/json" \
    -d "$JSON" 2>/dev/null)

# ── Apply speed limits from panel response ────────────────────────────────────
COMMANDS=$(echo "$RESPONSE" | grep -oP '(?<="commands":)\[.*?\]' 2>/dev/null)
if [ -n "$COMMANDS" ] && [ "$COMMANDS" != "[]" ]; then
    # Simple extraction: each {"username":"X","limit_kbps":N}
    echo "$COMMANDS" | grep -oP '\{[^}]+\}' | while IFS= read -r cmd; do
        UNAME=$(echo "$cmd" | grep -oP '(?<="username":")[^"]+')
        LIMIT=$(echo "$cmd" | grep -oP '(?<="limit_kbps":)\d+')
        [ -z "$UNAME" ] && continue

        # Find this user's VPN IP from OpenVPN routing table
        VPN_USER_IP=""
        for STATUS_LOG in /var/log/openvpn/openvpn-status.log /tmp/openvpn-status.log; do
            [ ! -f "$STATUS_LOG" ] && continue
            VPN_USER_IP=$(grep "^ROUTING_TABLE,$UNAME," "$STATUS_LOG" 2>/dev/null | cut -d',' -f2 | head -1)
            [ -n "$VPN_USER_IP" ] && break
        done

        if [ -n "$VPN_USER_IP" ]; then
            IFACE=$(ip route | grep "10.8.0.0" | awk '{print $3}' | head -1 || echo "tun0")
            if [ "${LIMIT:-0}" -gt 0 ]; then
                # Apply tc rate limit (HTB)
                RATE="${LIMIT}kbit"
                # Add root qdisc if not present
                tc qdisc show dev "$IFACE" 2>/dev/null | grep -q "htb" || \
                    tc qdisc add dev "$IFACE" root handle 1: htb default 999 2>/dev/null
                # Hash filter for this IP → class
                CLASSID=$(printf '%x' $(echo "$VPN_USER_IP" | awk -F'.' '{print $4}'))
                tc class add dev "$IFACE" parent 1: classid "1:$CLASSID" htb rate "$RATE" ceil "$RATE" 2>/dev/null || \
                    tc class change dev "$IFACE" parent 1: classid "1:$CLASSID" htb rate "$RATE" ceil "$RATE" 2>/dev/null
                tc filter add dev "$IFACE" parent 1: protocol ip prio 1 u32 \
                    match ip dst "$VPN_USER_IP/32" flowid "1:$CLASSID" 2>/dev/null
            else
                # Remove limit
                tc filter del dev "$IFACE" parent 1: protocol ip 2>/dev/null
            fi
        fi
    done
fi

rm -f "$TMP_FILE"
exit 0

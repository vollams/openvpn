#!/bin/bash
## xray_monitor.sh — real-time Xray connection monitor
## Online: instant on 'accepted' log line
## Offline: dual condition — log idle >=90s AND bytes delta <2000/20s

_APISERVER="127.0.0.1:62789"
_XRAY=$(command -v xray || true)
[[ -z "$_XRAY" ]] && exit 1

source /etc/.db-base 2>/dev/null || source /etc/xray/.db-base 2>/dev/null || exit 1
DB_HOST="${HOST}"; DB_USER="${USER}"; DB_PASS="${PASS}"; DB_NAME="${DBNAME:-$DB}"
server_ip=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')
XRAY_LOG="/var/log/xray/access.log"
STATE_FILE="/etc/xray/.monitor_state"
LAST_SEEN_FILE="/etc/xray/.ip_last_seen"

touch "$STATE_FILE" "$LAST_SEEN_FILE"

db_q()  { mysql --ssl-verify-server-cert=OFF -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -e "$1" 2>/dev/null; }
db_sN() { mysql --ssl-verify-server-cert=OFF -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -sN -e "$1" 2>/dev/null; }

update_count() {
    local cnt=$(db_sN "SELECT COUNT(*) FROM users WHERE is_connected_xray=1 AND active_address!='' AND active_address!='$server_ip';")
    db_q "UPDATE server_list SET online='${cnt:-0}', status='1' WHERE server_ip='$server_ip';"
}

mark_online() {
    local user="$1" ip="$2" now=$(date +"%Y-%m-%d %T")
    db_q "UPDATE users SET is_connected=1,is_connected_xray=1,active_address='$ip',active_date='$now' WHERE user_name='$user';"
    db_q "UPDATE users SET is_connected=0,is_connected_xray=0,active_address='' WHERE active_address='$ip' AND user_name!='$user';"
    sed -i "/|${user}$/d; /^${ip}|/d" "$STATE_FILE" 2>/dev/null
    echo "${ip}|${user}" >> "$STATE_FILE"
    sed -i "/^${ip} /d" "$LAST_SEEN_FILE" 2>/dev/null
    echo "${ip} $(date +%s)" >> "$LAST_SEEN_FILE"
    update_count
    echo "[monitor] ONLINE: $user from $ip"
}

get_stats() {
    # Returns: uplink downlink (inbound cumulative, never reset)
    local raw=$($_XRAY api statsquery --server=$_APISERVER 2>/dev/null)
    local up=$(echo "$raw" | awk '/"name":.*user.*shared.*uplink/{f=1} f && /"value":/{gsub(/[^0-9]/,"",$0); if($0+0>0){print $0+0}; f=0}' | awk '{s+=$1} END{printf "%.0f",s+0}')
    local dn=$(echo "$raw" | awk '/"name":.*user.*shared.*downlink/{f=1} f && /"value":/{gsub(/[^0-9]/,"",$0); if($0+0>0){print $0+0}; f=0}' | awk '{s+=$1} END{printf "%.0f",s+0}')
    echo "${up:-0} ${dn:-0}"
}

# Background loop: bytes-delta BW flush + per-IP log-idle offline detection
# NEVER uses reset:true — tracks cumulative baseline for DB diff
offline_watcher() {
    # Startup cleanup: only mark offline IPv4-addressed users not in state file
    # (IPv6 users are managed by auth.php — leave them alone)
    ALL_ONLINE=$(db_sN "SELECT user_name FROM users WHERE is_connected_xray=1 AND active_address REGEXP '^[0-9]{1,3}[.][0-9]{1,3}[.][0-9]{1,3}[.][0-9]{1,3}$';")
    while IFS= read -r db_user; do
        [[ -z "$db_user" ]] && continue
        grep -q "|${db_user}$" "$STATE_FILE" 2>/dev/null && continue
        echo "[offline_watcher] startup: $db_user not in state -> OFFLINE"
        db_q "UPDATE users SET is_connected=0,is_connected_xray=0,active_address='' WHERE user_name='$db_user';"
    done <<< "$ALL_ONLINE"
    update_count

    read PREV_UP PREV_DN <<< $(get_stats)
    local DB_UP_BASE=$PREV_UP
    local DB_DN_BASE=$PREV_DN
    local LAST_BW_FLUSH=$(date +%s)
    echo "[offline_watcher] started seed UP=$PREV_UP DN=$PREV_DN"

    while true; do
        sleep 20
        NOW_TS=$(date +%s)

        # Clean only server_ip-addressed users (old xray_stats.sh residue)
        # IPv6 users are real connections managed by auth.php — do NOT clean them here
        STALE_SRVIP=$(db_sN "SELECT user_name FROM users WHERE is_connected_xray=1 AND active_address='$server_ip';")
        while IFS= read -r stale_user; do
            [[ -z "$stale_user" ]] && continue
            echo "[offline_watcher] $stale_user has server_ip address (stale) -> OFFLINE"
            db_q "UPDATE users SET is_connected=0,is_connected_xray=0,active_address='' WHERE user_name='$stale_user';"
            update_count
        done <<< "$STALE_SRVIP"

        if [[ ! -s "$STATE_FILE" ]]; then
            read PREV_UP PREV_DN <<< $(get_stats)
            DB_UP_BASE=$PREV_UP; DB_DN_BASE=$PREV_DN
            continue
        fi
        # Only track IPv4-addressed users — IPv6 users are managed by auth.php
        ONLINE_DB=$(db_sN "SELECT user_name FROM users WHERE is_connected_xray=1 AND active_address REGEXP '^[0-9]{1,3}[.][0-9]{1,3}[.][0-9]{1,3}[.][0-9]{1,3}$' AND active_address NOT IN ('','$server_ip');")
        if [[ -z "$ONLINE_DB" ]]; then
            > "$STATE_FILE"
            read PREV_UP PREV_DN <<< $(get_stats)
            DB_UP_BASE=$PREV_UP; DB_DN_BASE=$PREV_DN
            continue
        fi

        # Read current cumulative (no reset — ever)
        read CUR_UP CUR_DN <<< $(get_stats)
        DELTA=$(( (CUR_UP + CUR_DN) - (PREV_UP + PREV_DN) ))
        echo "[offline_watcher] delta=$DELTA users=$(echo "$ONLINE_DB" | tr '\n' ',')"

        # Flush BW to ALL connected users (IPv4 + IPv6) every 60s
        ALL_CONNECTED=$(db_sN "SELECT user_name FROM users WHERE is_connected_xray=1 AND active_address!='' AND active_address!='$server_ip';")
        if [[ $(( NOW_TS - LAST_BW_FLUSH )) -ge 60 ]]; then
            ADD_UP=$(( CUR_UP - DB_UP_BASE ))
            ADD_DN=$(( CUR_DN - DB_DN_BASE ))
            if [[ "$ADD_UP" -gt 0 || "$ADD_DN" -gt 0 ]]; then
                while IFS= read -r user; do
                    [[ -z "$user" ]] && continue
                    db_q "UPDATE users SET bytes_sent=bytes_sent+${ADD_UP}, bytes_received=bytes_received+${ADD_DN} WHERE user_name='$user';"
                done <<< "$ALL_CONNECTED"
                echo "[offline_watcher] bw flush UP=$ADD_UP DN=$ADD_DN to $(echo "$ALL_CONNECTED" | tr '\n' ',')"
                DB_UP_BASE=$CUR_UP
                DB_DN_BASE=$CUR_DN
            fi
            LAST_BW_FLUSH=$NOW_TS
        fi

        # --- Orphan cleanup: DB says online but NOT in state file → mark offline ---
        while IFS= read -r db_user; do
            [[ -z "$db_user" ]] && continue
            grep -q "|${db_user}$" "$STATE_FILE" 2>/dev/null && continue
            echo "[offline_watcher] $db_user in DB but missing from state → OFFLINE"
            db_q "UPDATE users SET is_connected=0,is_connected_xray=0,active_address='' WHERE user_name='$db_user';"
            update_count
        done <<< "$ONLINE_DB"

        # Per-IP offline check: log idle >=60s (3 cycles of no accepted log entry)
        # NOTE: delta NOT used per-IP — shared UUID means all IPs share one counter
        while IFS='|' read -r tip tuser; do
            [[ -z "$tip" || -z "$tuser" ]] && continue
            LAST_SEEN=$(grep "^${tip} " "$LAST_SEEN_FILE" 2>/dev/null | awk '{print $2}')
            [[ -z "$LAST_SEEN" ]] && LAST_SEEN=$NOW_TS
            IDLE=$(( NOW_TS - LAST_SEEN ))
            echo "[offline_watcher] $tuser ($tip) log_idle=${IDLE}s delta=$DELTA"
            if [[ "$IDLE" -ge 60 ]]; then
                ADD_UP=$(( CUR_UP - DB_UP_BASE ))
                ADD_DN=$(( CUR_DN - DB_DN_BASE ))
                [[ "$ADD_UP" -gt 0 || "$ADD_DN" -gt 0 ]] && \
                    db_q "UPDATE users SET bytes_sent=bytes_sent+${ADD_UP}, bytes_received=bytes_received+${ADD_DN} WHERE user_name='$tuser';"
                db_q "UPDATE users SET is_connected=0,is_connected_xray=0,active_address='' WHERE user_name='$tuser';"
                sed -i "/|${tuser}$/d" "$STATE_FILE" 2>/dev/null
                sed -i "/^${tip} /d" "$LAST_SEEN_FILE" 2>/dev/null
                DB_UP_BASE=$CUR_UP; DB_DN_BASE=$CUR_DN
                echo "[offline_watcher] $tuser -> OFFLINE (log_idle=${IDLE}s)"
                update_count
            fi
        done < <(cat "$STATE_FILE")

        # Always advance — delta is always the true last-20s increment
        PREV_UP=$CUR_UP
        PREV_DN=$CUR_DN
    done
}

offline_watcher &
WATCHER_PID=$!
trap "kill $WATCHER_PID 2>/dev/null; exit" EXIT INT TERM

echo "[monitor] Starting. SERVER_IP=$server_ip watcher=$WATCHER_PID"

tail -F "$XRAY_LOG" 2>/dev/null | while IFS= read -r line; do
    [[ "$line" != *" accepted "* ]] && continue
    [[ "$line" != *"email: shared"* ]] && continue

    CLIENT_IP=$(echo "$line" | grep -oP 'from \K[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}')
    [[ -z "$CLIENT_IP" ]] && continue
    [[ "$CLIENT_IP" =~ ^(127\.|188\.114\.) ]] && continue

    # Update last-seen timestamp for this IP
    sed -i "/^${CLIENT_IP} /d" "$LAST_SEEN_FILE" 2>/dev/null
    echo "${CLIENT_IP} $(date +%s)" >> "$LAST_SEEN_FILE"

    # Already tracked in state file?
    EXISTING=$(grep "^${CLIENT_IP}|" "$STATE_FILE" 2>/dev/null | cut -d'|' -f2 | head -1)
    if [[ -n "$EXISTING" ]]; then
        # Check if auth.php has assigned this IP to a DIFFERENT user (user switch on same IP)
        AUTH_USER=$(db_sN "SELECT user_name FROM users WHERE active_address='$CLIENT_IP' AND duration>0 AND is_freeze=0 AND user_name REGEXP '^[a-zA-Z]' AND user_name!='$EXISTING' ORDER BY active_date DESC LIMIT 1;")
        if [[ -n "$AUTH_USER" ]]; then
            echo "[monitor] IP switch: $EXISTING -> $AUTH_USER on $CLIENT_IP"
            db_q "UPDATE users SET is_connected=0,is_connected_xray=0,active_address='' WHERE user_name='$EXISTING';"
            sed -i "/|${EXISTING}$/d; /^${CLIENT_IP}|/d" "$STATE_FILE" 2>/dev/null
            mark_online "$AUTH_USER" "$CLIENT_IP"
            continue
        fi
        # Verify DB still has this user online — stale state entry check
        STILL_ON=$(db_sN "SELECT COUNT(*) FROM users WHERE user_name='$EXISTING' AND is_connected_xray=1;")
        if [[ "${STILL_ON:-0}" -gt 0 ]]; then
            db_q "UPDATE users SET active_date='$(date +"%Y-%m-%d %T")' WHERE user_name='$EXISTING' AND is_connected_xray=1;"
            continue
        fi
        # Stale: DB says offline but state file still has entry — clean it up
        echo "[monitor] stale state: $EXISTING ($CLIENT_IP) offline in DB, removing"
        sed -i "/^${CLIENT_IP}|/d" "$STATE_FILE" 2>/dev/null
        sed -i "/^${CLIENT_IP} /d" "$LAST_SEEN_FILE" 2>/dev/null
    fi

    # Trust auth.php active_address assignment first
    NEW_USER=$(db_sN "SELECT user_name FROM users WHERE active_address='$CLIENT_IP' AND duration>0 AND is_freeze=0 AND user_name REGEXP '^[a-zA-Z]' ORDER BY active_date DESC LIMIT 1;")
    # Fallback: most recently logged-in user with a real alphabetic username
    [[ -z "$NEW_USER" ]] && NEW_USER=$(db_sN "SELECT user_name FROM users WHERE is_connected_xray=0 AND active_address='' AND user_level NOT IN ('superadmin','developer','reseller') AND duration>0 AND is_freeze=0 AND user_name REGEXP '^[a-zA-Z]' ORDER BY active_date DESC LIMIT 1;")
    [[ -z "$NEW_USER" ]] && continue

    mark_online "$NEW_USER" "$CLIENT_IP"
done

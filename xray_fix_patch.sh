#!/bin/bash
## Xray Live Server Patch Script
## Run this on the VPS as root to fix xray stats + online tracking
## Usage: bash xray_fix_patch.sh

set -e

echo "[1/5] Detecting xray binary and config..."
XRAY_BIN=$(command -v xray || echo "")
if [[ -z "$XRAY_BIN" ]]; then
    echo "ERROR: xray binary not found"
    exit 1
fi
echo "    xray: $XRAY_BIN"

# Determine config path
if [[ -f /usr/local/etc/xray/config.json ]]; then
    CONFIG=/usr/local/etc/xray/config.json
elif [[ -f /etc/xray/config.json ]]; then
    CONFIG=/etc/xray/config.json
else
    echo "ERROR: xray config.json not found"
    exit 1
fi
echo "    config: $CONFIG"

echo "[2/5] Patching xray config.json with API inbound + stats + policy..."
python3 - <<PYEOF
import json, sys

with open('$CONFIG', 'r') as f:
    cfg = json.load(f)

# Add api section
cfg['api'] = {"services": ["HandlerService", "LoggerService", "StatsService"], "tag": "api"}

# Add stats section
cfg['stats'] = {}

# Add policy section
cfg['policy'] = {
    "levels": {"0": {"statsUserDownlink": True, "statsUserUplink": True}},
    "system": {"statsInboundUplink": True, "statsInboundDownlink": True,
                "statsOutboundUplink": True, "statsOutboundDownlink": True}
}

# Add API inbound at the front if not already present
api_inbound = {
    "listen": "127.0.0.1",
    "port": 62789,
    "protocol": "dokodemo-door",
    "settings": {"address": "127.0.0.1"},
    "tag": "api"
}

# Check if api inbound already exists
has_api = any(ib.get('tag') == 'api' for ib in cfg.get('inbounds', []))
if not has_api:
    cfg['inbounds'].insert(0, api_inbound)
    print("  + Added API inbound")
else:
    # Make sure existing one uses dokodemo-door
    for ib in cfg['inbounds']:
        if ib.get('tag') == 'api':
            ib['protocol'] = 'dokodemo-door'
            ib['port'] = 62789
            ib['listen'] = '127.0.0.1'
            print("  + Fixed existing API inbound protocol")
            break

# Ensure routing has api rule
if 'routing' not in cfg:
    cfg['routing'] = {"rules": []}
rules = cfg['routing'].get('rules', [])
has_api_rule = any(r.get('inboundTag') == ['api'] or 'api' in r.get('inboundTag', []) for r in rules)
if not has_api_rule:
    rules.insert(0, {"type": "field", "inboundTag": ["api"], "outboundTag": "api"})
    cfg['routing']['rules'] = rules
    print("  + Added API routing rule")

# Ensure outbounds has an 'api' outbound tag (Xray needs it for routing to work)
outbounds = cfg.get('outbounds', [])
# The routing rule with outboundTag: "api" works when the inbound itself is the api tag
# No separate outbound needed — Xray handles api internally

with open('$CONFIG', 'w') as f:
    json.dump(cfg, f, indent=2)
print("  Config written OK")
PYEOF

echo "[3/5] Writing xray_stats.sh and xray_checker.sh..."
server_ip=$(curl -s https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')
mkdir -p /etc/xray

cat >/etc/xray/xray_stats.sh <<XSEOF
#!/bin/bash
_APISERVER=127.0.0.1:62789
_XRAY=\$(command -v xray || true)
if [[ -z "\$_XRAY" ]]; then exit 1; fi
datenow=\$(date +"%Y-%m-%d %T")
server_ip=$server_ip
if [[ -f /etc/xray/.db-base ]]; then . /etc/xray/.db-base; elif [[ -f /etc/.db-base ]]; then . /etc/.db-base; fi
DB_HOST="\${HOST:-localhost}"
DB_USER="\${USER}"
DB_PASS="\${PASS}"
DB_NAME="\${DBNAME:-\$DB}"
apidata() {
    local ARGS=
    if [[ \$1 == "reset" ]]; then ARGS="reset: true"; fi
    \$_XRAY api statsquery --server=\$_APISERVER \${ARGS} 2>/dev/null \
    | awk '{
        if (match(\$1, /"name":/)) {
            f=1; gsub(/^"|",?\$/, "", \$2);
            split(\$2, p, ">>>");
            printf "%s:%s->%s\t", p[1], p[2], p[4];
        } else if (match(\$1, /"value":/) && f) {
            f=0; gsub(/"/, "", \$2); printf "%.0f\n", \$2;
        } else if (match(\$0, /}/) && f) { f=0; print 0; }
    }'
}
process_users_to_mysql() {
    declare -A UP
    declare -A DOWN
    while IFS=\$'\t' read -r line; do
        user=\$(echo "\$line" | awk -F'[:-> \t]+' '/^user:/ {print \$2}')
        user="\${user%-}"
        user="\${user%@vless}"
        dir=\$(echo "\$line" | awk -F'[:-> \t]+' '/^user:/ {print \$3}')
        val=\$(echo "\$line" | awk '{print \$2}')
        [[ -z "\$user" || -z "\$dir" || -z "\$val" ]] && continue
        if [[ "\$dir" == "up" ]]; then UP["\$user"]=\$val
        else DOWN["\$user"]=\$val; fi
    done <<< "\$DATA"
    ALL_USERS=(\$(printf "%s\n" "\${!UP[@]}" "\${!DOWN[@]}" | sort -u))
    for user in "\${ALL_USERS[@]}"; do
        up=\${UP[\$user]:-0}
        down=\${DOWN[\$user]:-0}
        mysql --ssl-verify-server-cert=OFF -h "\$DB_HOST" -u "\$DB_USER" -p"\$DB_PASS" "\$DB_NAME" -e \
"UPDATE users SET bytes_sent=bytes_sent+\$up, bytes_received=bytes_received+\$down, device_connected=1, is_connected_xray=1, is_connected=1, active_address='\$server_ip', active_date='\$datenow' WHERE user_name='\$user';" 2>/dev/null
    done
}
DATA=\$(apidata "\$1")
process_users_to_mysql
XSEOF
chmod +x /etc/xray/xray_stats.sh
echo "    xray_stats.sh written"

cat >/etc/xray/xray_checker.sh <<XCEOF
#!/bin/bash
_APISERVER="127.0.0.1:62789"
_XRAY=\$(command -v xray || true)
if [[ -z "\$_XRAY" ]]; then exit 1; fi
datenow=\$(date +"%Y-%m-%d %T")
server_ip=$server_ip
if [[ -f /etc/xray/.db-base ]]; then . /etc/xray/.db-base; elif [[ -f /etc/.db-base ]]; then . /etc/.db-base; else exit 1; fi
DB_HOST="\${HOST:-localhost}"
DB_USER="\${USER}"
DB_PASS="\${PASS}"
DB_NAME="\${DBNAME:-\$DB}"
XRAY_ACCESS_LOG="/var/log/xray/access.log"
DATA="\$(\$_XRAY api statsquery --server=\$_APISERVER 2>/dev/null)"
ONLINE_USERS=(\$(
    echo "\$DATA" \
    | grep '"name": "user' \
    | sed -E 's/.*user>>>([^>]+)>>>.*/\1/' \
    | sed 's/@vless\$//' \
    | grep -v '^shared\$' \
    | sort -u
))
if [[ \${#ONLINE_USERS[@]} -gt 0 ]]; then
    ACTIVE_LIST=\$(printf "'%s'," "\${ONLINE_USERS[@]}")
    ACTIVE_LIST="\${ACTIVE_LIST%,}"
    mysql --ssl-verify-server-cert=OFF -h "\$DB_HOST" -u "\$DB_USER" -p"\$DB_PASS" "\$DB_NAME" -e \
"UPDATE users SET is_connected=1, is_connected_xray=1, active_address='\$server_ip', active_date='\$datenow' WHERE user_name IN (\$ACTIVE_LIST);" 2>/dev/null
    mysql --ssl-verify-server-cert=OFF -h "\$DB_HOST" -u "\$DB_USER" -p"\$DB_PASS" "\$DB_NAME" -e \
"UPDATE users SET is_connected=0, is_connected_xray=0, active_address='', active_date='' WHERE active_address='\$server_ip' AND user_name NOT IN (\$ACTIVE_LIST);" 2>/dev/null
    ONLINE_COUNT=\${#ONLINE_USERS[@]}
    mysql --ssl-verify-server-cert=OFF -h "\$DB_HOST" -u "\$DB_USER" -p"\$DB_PASS" "\$DB_NAME" -e \
"UPDATE server_list SET online='\$ONLINE_COUNT' WHERE server_ip='\$server_ip';" 2>/dev/null
    exit 0
fi
if [[ ! -f "\$XRAY_ACCESS_LOG" ]]; then
    mysql --ssl-verify-server-cert=OFF -h "\$DB_HOST" -u "\$DB_USER" -p"\$DB_PASS" "\$DB_NAME" -e \
"UPDATE users SET is_connected=0, is_connected_xray=0, active_address='' WHERE is_connected_xray=1 AND active_address NOT IN ('','\$server_ip');" 2>/dev/null
    mysql --ssl-verify-server-cert=OFF -h "\$DB_HOST" -u "\$DB_USER" -p"\$DB_PASS" "\$DB_NAME" -e \
"UPDATE server_list SET online=0 WHERE server_ip='\$server_ip';" 2>/dev/null
    exit 0
fi
MINUTE1=\$(date '+%Y/%m/%d %H:%M' 2>/dev/null)
MINUTE2=\$(date -d '1 minute ago' '+%Y/%m/%d %H:%M' 2>/dev/null)
MINUTE3=\$(date -d '2 minutes ago' '+%Y/%m/%d %H:%M' 2>/dev/null)
ACTIVE_IPS=(\$(grep -E "^(\$MINUTE1|\$MINUTE2|\$MINUTE3)" "\$XRAY_ACCESS_LOG" 2>/dev/null | grep ' accepted ' | grep -oP 'from \K[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | grep -v '^127\.' | sort -u))
if [[ \${#ACTIVE_IPS[@]} -eq 0 ]]; then
    mysql --ssl-verify-server-cert=OFF -h "\$DB_HOST" -u "\$DB_USER" -p"\$DB_PASS" "\$DB_NAME" -e \
"UPDATE users SET is_connected=0, is_connected_xray=0, active_address='' WHERE is_connected_xray=1 AND active_address NOT IN ('','\$server_ip');" 2>/dev/null
    mysql --ssl-verify-server-cert=OFF -h "\$DB_HOST" -u "\$DB_USER" -p"\$DB_PASS" "\$DB_NAME" -e \
"UPDATE server_list SET online=0 WHERE server_ip='\$server_ip';" 2>/dev/null
    exit 0
fi
IP_LIST=\$(printf "'%s'," "\${ACTIVE_IPS[@]}")
IP_LIST="\${IP_LIST%,}"
mysql --ssl-verify-server-cert=OFF -h "\$DB_HOST" -u "\$DB_USER" -p"\$DB_PASS" "\$DB_NAME" -e \
"UPDATE users SET is_connected=1, is_connected_xray=1, active_date='\$datenow' WHERE active_address IN (\$IP_LIST);" 2>/dev/null
mysql --ssl-verify-server-cert=OFF -h "\$DB_HOST" -u "\$DB_USER" -p"\$DB_PASS" "\$DB_NAME" -e \
"UPDATE users SET is_connected=0, is_connected_xray=0, active_address='' WHERE is_connected_xray=1 AND active_address NOT IN (\$IP_LIST,'','\$server_ip');" 2>/dev/null
ONLINE_COUNT=\$(mysql --ssl-verify-server-cert=OFF -h "\$DB_HOST" -u "\$DB_USER" -p"\$DB_PASS" "\$DB_NAME" -sN -e \
"SELECT COUNT(*) FROM users WHERE is_connected_xray=1 AND active_address IN (\$IP_LIST);" 2>/dev/null || echo 0)
mysql --ssl-verify-server-cert=OFF -h "\$DB_HOST" -u "\$DB_USER" -p"\$DB_PASS" "\$DB_NAME" -e \
"UPDATE server_list SET online='\$ONLINE_COUNT' WHERE server_ip='\$server_ip';" 2>/dev/null
XCEOF
chmod +x /etc/xray/xray_checker.sh
echo "    xray_checker.sh written"

echo "[3b/5] Ensuring xray config preserves original UUID + adds email=shared for stats..."
# IMPORTANT: AIO uses a single shared UUID for all clients.
# We must NOT replace it with per-user UUIDs — that breaks existing connections.
# We only ensure email='shared' is set so xray tracks stats under that tag.
# Online detection uses access log IP matching (Mode 2 in xray_checker.sh).
python3 -c "
import json
cfg = json.load(open('$CONFIG'))
for ib in cfg.get('inbounds', []):
    proto = ib.get('protocol','')
    if proto in ('vless','vmess','trojan') and ib.get('tag') != 'api':
        s = ib.setdefault('settings', {})
        clients = s.get('clients', [])
        # Only add email if missing — never change the UUID
        for c in clients:
            if 'email' not in c:
                c['email'] = 'shared'
            if 'level' not in c:
                c['level'] = 0
with open('$CONFIG', 'w') as f:
    json.dump(cfg, f, indent=2)
print('    UUID preserved, email=shared set')
" 2>/dev/null || echo "    (email patch skipped)"

# Remove any stale regen hooks that would break config
sed -i '/xray_config_regen/d' /home/authentication.sh 2>/dev/null || true
sed -i '/xray_config_regen/d' /etc/cron.d/xray_stats 2>/dev/null || true
rm -f /etc/xray/xray_config_regen.sh /etc/xray/xray_config_regen.py 2>/dev/null || true
echo "    regen hooks removed (access log IP matching used instead)"

echo "[4/5] Installing cron jobs..."
if ! grep -q "xray_stats.sh" /etc/cron.d/xray_stats 2>/dev/null; then
    echo -e "* *\t* * *\troot\tbash /etc/xray/xray_stats.sh" > /etc/cron.d/xray_stats
    echo "    xray_stats cron installed"
else
    echo "    xray_stats cron already exists"
fi
if ! grep -q "xray_checker.sh" /etc/cron.d/xray_checker 2>/dev/null; then
    echo -e "* *\t* * *\troot\tbash /etc/xray/xray_checker.sh" > /etc/cron.d/xray_checker
    echo "    xray_checker cron installed"
else
    echo "    xray_checker cron already exists"
fi

echo "[5/5] Restarting xray..."
systemctl restart xray
sleep 2
systemctl is-active xray && echo "    xray running OK" || echo "    WARNING: xray may have failed to start"

echo ""
echo "=== Patch complete. Testing API ==="
sleep 1
$XRAY_BIN api statsquery --server=127.0.0.1:62789 2>&1 | head -5 || echo "API not responding yet (normal if no users connected)"
echo ""
echo "=== Testing DB credentials ==="
. /etc/.db-base
mysql --ssl-verify-server-cert=OFF -h "${HOST:-localhost}" -u "$USER" -p"$PASS" "$DBNAME" -e "SELECT COUNT(*) as total_users FROM users LIMIT 1;" 2>&1
echo ""
echo "Done! Connect an xray client and wait up to 60s for stats to update."

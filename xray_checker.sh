#!/bin/bash
## Xray online/offline updater
## Supports two modes:
##   1) Per-user email stats (debian_xray/vless — unique UUID per user)
##   2) Access log IP matching (AIO — shared UUID, user IP set by auth.php)

_APISERVER="127.0.0.1:62789"
_XRAY=$(command -v xray || true)
if [[ -z "$_XRAY" ]]; then exit 1; fi

datenow=$(date +"%Y-%m-%d %T")
server_ip=SERVER_IP

# Load credentials from either location
if [[ -f /etc/xray/.db-base ]]; then
    . /etc/xray/.db-base
elif [[ -f /etc/.db-base ]]; then
    . /etc/.db-base
else
    exit 1
fi
DB_HOST="${HOST:-localhost}"
DB_USER="${USER}"
DB_PASS="${PASS}"
DB_NAME="${DBNAME:-$DB}"

XRAY_ACCESS_LOG="/var/log/xray/access.log"

# ======================================================
# MODE 1: Try per-user stats from API (per-user UUID setup)
# ======================================================
DATA="$($_XRAY api statsquery --server=$_APISERVER 2>/dev/null)"

ONLINE_USERS=($(
    echo "$DATA" \
    | grep '"name": "user' \
    | sed -E 's/.*user>>>([^>]+)>>>.*/\1/' \
    | sed 's/@vless$//' \
    | grep -v '^shared$' \
    | sort -u
))

if [[ ${#ONLINE_USERS[@]} -gt 0 ]]; then
    # Per-user UUID mode: use API stats
    ACTIVE_LIST=$(printf "'%s'," "${ONLINE_USERS[@]}")
    ACTIVE_LIST="${ACTIVE_LIST%,}"

    mysql --ssl-verify-server-cert=OFF -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -e \
"UPDATE users SET is_connected=1, is_connected_xray=1, active_address='$server_ip', active_date='$datenow' WHERE user_name IN ($ACTIVE_LIST);" 2>/dev/null

    mysql --ssl-verify-server-cert=OFF -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -e \
"UPDATE users SET is_connected=0, is_connected_xray=0, active_address='', active_date='' WHERE active_address='$server_ip' AND user_name NOT IN ($ACTIVE_LIST);" 2>/dev/null

    ONLINE_COUNT=${#ONLINE_USERS[@]}
    mysql --ssl-verify-server-cert=OFF -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -e \
"UPDATE server_list SET online='$ONLINE_COUNT', last_update=NOW() WHERE server_ip='$server_ip';" 2>/dev/null
    exit 0
fi

# ======================================================
# MODE 2: Shared UUID — use access log IP matching
# active_address is set by auth.php when user logs in via app
# ======================================================
if [[ ! -f "$XRAY_ACCESS_LOG" ]]; then
    # No API users, no access log — mark all offline
    mysql --ssl-verify-server-cert=OFF -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -e \
"UPDATE users SET is_connected=0, is_connected_xray=0, active_address='' WHERE is_connected_xray=1 AND active_address NOT IN ('','$server_ip');" 2>/dev/null
    mysql --ssl-verify-server-cert=OFF -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -e \
"UPDATE server_list SET online=0, last_update=NOW() WHERE server_ip='$server_ip';" 2>/dev/null
    exit 0
fi

# Get IPs with accepted connections in last 120 seconds
# Generate last 2 minute timestamps and grep log lines matching them
MINUTE1=$(date '+%Y/%m/%d %H:%M' 2>/dev/null)
MINUTE2=$(date -d '1 minute ago' '+%Y/%m/%d %H:%M' 2>/dev/null)
MINUTE3=$(date -d '2 minutes ago' '+%Y/%m/%d %H:%M' 2>/dev/null)
ACTIVE_IPS=($(grep -E "^($MINUTE1|$MINUTE2|$MINUTE3)" "$XRAY_ACCESS_LOG" 2>/dev/null \
    | grep ' accepted ' \
    | grep -oP 'from \K[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' \
    | grep -v '^127\.' \
    | sort -u))

if [[ ${#ACTIVE_IPS[@]} -eq 0 ]]; then
    # No recent connections
    mysql --ssl-verify-server-cert=OFF -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -e \
"UPDATE users SET is_connected=0, is_connected_xray=0 WHERE is_connected_xray=1 AND active_address='$server_ip';" 2>/dev/null
    mysql --ssl-verify-server-cert=OFF -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -e \
"UPDATE server_list SET online=0, last_update=NOW() WHERE server_ip='$server_ip';" 2>/dev/null
    exit 0
fi

# Build IP list for SQL
IP_LIST=$(printf "'%s'," "${ACTIVE_IPS[@]}")
IP_LIST="${IP_LIST%,}"

# Mark users whose active_address matches an active IP as online
mysql --ssl-verify-server-cert=OFF -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -e \
"UPDATE users SET is_connected=1, is_connected_xray=1, active_date='$datenow' WHERE active_address IN ($IP_LIST);" 2>/dev/null

# Mark users on this server with IPs no longer active as offline
mysql --ssl-verify-server-cert=OFF -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -e \
"UPDATE users SET is_connected=0, is_connected_xray=0, active_address='' WHERE is_connected_xray=1 AND active_address NOT IN ($IP_LIST) AND active_address NOT IN ('', '$server_ip');" 2>/dev/null

# Count online users for this server (by matching their active_address IPs to xray port connections)
ONLINE_COUNT=$(mysql --ssl-verify-server-cert=OFF -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" \
    -sN -e "SELECT COUNT(*) FROM users WHERE is_connected_xray=1 AND active_address IN ($IP_LIST);" 2>/dev/null || echo 0)
mysql --ssl-verify-server-cert=OFF -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -e \
"UPDATE server_list SET online='$ONLINE_COUNT', last_update=NOW() WHERE server_ip='$server_ip';" 2>/dev/null

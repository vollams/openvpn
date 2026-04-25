#!/bin/bash
## xray_checker.sh — only syncs server_list.online count
## Offline detection is handled by xray_monitor.sh (systemd service)
## DO NOT add reset:true here — it destroys xray_monitor.sh cumulative baseline

source /etc/.db-base 2>/dev/null || source /etc/xray/.db-base 2>/dev/null || exit 1
DB_HOST="${HOST}"; DB_USER="${USER}"; DB_PASS="${PASS}"; DB_NAME="${DBNAME:-$DB}"
server_ip=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')

CNT=$(mysql --ssl-verify-server-cert=OFF -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" \
    -sN -e "SELECT COUNT(*) FROM users WHERE is_connected_xray=1 AND active_address!='' AND active_address!='$server_ip';" 2>/dev/null || echo 0)
mysql --ssl-verify-server-cert=OFF -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -e \
"UPDATE server_list SET online='${CNT:-0}', status='1' WHERE server_ip='$server_ip';" 2>/dev/null

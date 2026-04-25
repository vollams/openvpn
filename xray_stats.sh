#!/bin/bash
## xray api + mysql stats script

# Xray API Config
_APISERVER=127.0.0.1:62789

# Try to automatically locate Xray binary
_XRAY=$(command -v xray || true)
if [[ -z "$_XRAY" ]]; then
    echo "Error: Xray binary not found. Please install Xray or specify its path."
    exit 1
fi

datenow=$(date +"%Y-%m-%d %T")
server_ip=$(curl -s https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')

# MySQL Config
if [[ -f /etc/xray/.db-base ]]; then . /etc/xray/.db-base; elif [[ -f /etc/.db-base ]]; then . /etc/.db-base; fi
DB_HOST="${HOST:-localhost}"
DB_USER="${USER}"
DB_PASS="${PASS}"
DB_NAME="${DBNAME:-$DB}"

apidata() {
    local ARGS=
    if [[ $1 == "reset" ]]; then
        ARGS="reset: true"
    fi

    $_XRAY api statsquery --server=$_APISERVER "${ARGS}" \
    | awk '{
        if (match($1, /"name":/)) {
            f=1;
            gsub(/^"|",?$/, "", $2);
            split($2, p, ">>>");
            printf "%s:%s->%s\t", p[1], p[2], p[4];
        }
        else if (match($1, /"value":/) && f) {
            f=0;
            gsub(/"/, "", $2);
            printf "%.0f\n", $2;
        }
        else if (match($0, /}/) && f) {
            f=0;
            print 0;
        }
    }'
}

print_sum() {
    local DATA="$1"
    local PREFIX="$2"
    local SORTED=$(echo "$DATA" | grep "^${PREFIX}" | sort -r)
    local SUM=$(echo "$SORTED" | awk '
        /->up/ { us += $2 }
        /->down/ { ds += $2 }
        END {
            printf "SUM->up:\t%.0f\nSUM->down:\t%.0f\nSUM->TOTAL:\t%.0f\n", us, ds, us + ds;
        }')

    echo -e "${SORTED}\n${SUM}" \
    | numfmt --field=2 --suffix=B --to=iec \
    | cat -t
}

process_users_to_mysql() {
    # MODE 1: per-user UUID only — skip shared users entirely
    declare -A UP
    declare -A DOWN

    while IFS=$'\t' read -r line; do
        user=$(echo "$line" | awk -F'[:-> \t]+' '/^user:/ {print $2}')
        user="${user%-}"
        user="${user%@vless}"
        [[ "$user" == "shared" || -z "$user" ]] && continue
        dir=$(echo "$line" | awk -F'[:-> \t]+' '/^user:/ {print $3}')
        val=$(echo "$line" | awk '{print $2}')
        [[ -z "$dir" || -z "$val" ]] && continue
        if [[ "$dir" == "up" ]]; then UP["$user"]=$val; else DOWN["$user"]=$val; fi
    done <<< "$DATA"

    ALL_USERS=($(printf "%s\n" "${!UP[@]}" "${!DOWN[@]}" | sort -u))
    [[ ${#ALL_USERS[@]} -eq 0 ]] && return

    for user in "${ALL_USERS[@]}"; do
        up=${UP[$user]:-0}
        down=${DOWN[$user]:-0}
        mysql --ssl-verify-server-cert=OFF -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -e \
"UPDATE users SET bytes_sent=bytes_sent+$up, bytes_received=bytes_received+$down WHERE user_name='$user';" 2>/dev/null
    done
}

# ---------------- MAIN -----------------

DATA=$(apidata)

# Per-user UUID mode only — shared UUID BW is handled by xray_monitor.sh
HAS_USER_STATS=$(echo "$DATA" | grep '^user:' | grep -vc ':shared->')
if [[ "$HAS_USER_STATS" -gt 0 ]]; then
    process_users_to_mysql
fi
# Shared UUID mode: xray_monitor.sh handles all BW flushing — do nothing here

echo "------------Inbound----------"
print_sum "$DATA" "inbound" 2>/dev/null
echo "-----------------------------"

echo "------------Outbound---------"
print_sum "$DATA" "outbound" 2>/dev/null
echo "-----------------------------"

echo
echo "-------------User------------"
print_sum "$DATA" "user" 2>/dev/null
echo "-----------------------------"

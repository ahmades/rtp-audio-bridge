#!/usr/bin/env bash

function is_ipv4() {
    local address=$1
    local octet
    local -a octets

    [[ "$address" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
    IFS=. read -r -a octets <<< "$address"
    for octet in "${octets[@]}"; do
        (( 10#$octet <= 255 )) || return 1
    done
}

function local_ipv4_interface() {
    ip -o -4 addr show | 
	awk -v address="$1" \
		'index($4, address "/") == 1 { print $2; found = 1; exit } END { if (!found) exit 1 }'
}

function local_ipv4_for_peer() {
    local peer=${1:-1.1.1.1}

    ip -o -4 route get "$peer" | awk '{ for (field = 1; field <= NF; field++) if ($field == "src") { print $(field + 1); found = 1; exit } } END { if (!found) exit 1 }'
}

function check_ip_reachable() {
    local address

    for address in "$@"; do
        [[ -n "$address" ]] || continue
        if ! ping -c 1 -W 2 "$address" >/dev/null 2>&1; then
            echo "Error: IP address is unreachable: $address" >&2
            return 1
        fi
    done
}
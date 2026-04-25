#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/home-netops-lib.sh"

load_config

PUBLIC_IP_URLS="${PUBLIC_IP_URLS:-https://ip.3322.net https://ddns.oray.com/checkip https://myip.ipip.net}"
PUBLIC_IP_TIMEOUT="${PUBLIC_IP_TIMEOUT:-8}"

get_public_ip() {
    local url ip a b c d

    for url in $PUBLIC_IP_URLS; do
        ip="$(curl -4 -fsS --max-time "$PUBLIC_IP_TIMEOUT" "$url" 2>/dev/null | tr -d '[:space:]' || true)"

        if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
            IFS='.' read -r a b c d <<< "$ip"
            if (( a <= 255 && b <= 255 && c <= 255 && d <= 255 )); then
                printf '%s\n' "$ip"
                return 0
            fi
        fi
    done

    return 1
}

get_public_ip

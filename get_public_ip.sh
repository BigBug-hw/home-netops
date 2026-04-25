#!/usr/bin/env bash
set -euo pipefail

get_public_ip() {
    local ip=""

    # 多个源做容错，避免某个服务临时不可用
    local urls=(
        "https://ip.3322.net"
        "https://ddns.oray.com/checkip"
        "https://myip.ipip.net"
        #"https://api.ipify.org"
        #"https://ifconfig.me/ip"
        #"https://4.ipw.cn"
    )

    for url in "${urls[@]}"; do
        ip="$(curl -4 -fsS --max-time 8 "$url" 2>/dev/null | tr -d '[:space:]' || true)"

        if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
            # 粗略校验每段 <= 255
            IFS='.' read -r a b c d <<< "$ip"
            if (( a <= 255 && b <= 255 && c <= 255 && d <= 255 )); then
                echo "$ip"
                return 0
            fi
        fi
    done

    return 1
}

printf '%s\n' "$(get_public_ip)"

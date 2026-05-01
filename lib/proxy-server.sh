#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"

load_config

EASYTIER_LAN_IP="${EASYTIER_LAN_IP:-}"
GOST_BIN="${GOST_BIN:-gost}"
PROXY_SOCKS_PORT="${PROXY_SOCKS_PORT:-1080}"
PROXY_HTTP_PORT="${PROXY_HTTP_PORT:-8080}"

main() {
    need_cmd "$GOST_BIN"
    [[ -n "$EASYTIER_LAN_IP" ]] || die "EASYTIER_LAN_IP must be set in $HOME_NETOPS_CONFIG"

    log "starting proxy server on EasyTier IP ${EASYTIER_LAN_IP}: socks5=${PROXY_SOCKS_PORT} http=${PROXY_HTTP_PORT}"
    exec "$GOST_BIN" \
        -L "socks5://${EASYTIER_LAN_IP}:${PROXY_SOCKS_PORT}" \
        -L "http://${EASYTIER_LAN_IP}:${PROXY_HTTP_PORT}"
}

main "$@"

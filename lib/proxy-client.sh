#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"

load_config

GOST_BIN="${GOST_BIN:-gost}"
PROXY_CLIENT_LISTEN_ADDR="${PROXY_CLIENT_LISTEN_ADDR:-127.0.0.1}"
PROXY_SERVER_IP="${PROXY_SERVER_IP:-}"
PROXY_SOCKS_PORT="${PROXY_SOCKS_PORT:-1080}"
PROXY_HTTP_PORT="${PROXY_HTTP_PORT:-8080}"
GOST_CONFIG="${GOST_CONFIG:-config/gost.yaml}"
GOST_CONFIG="$(resolve_app_path "$GOST_CONFIG")"

main() {
    need_cmd "$GOST_BIN"
    [[ -n "$PROXY_SERVER_IP" ]] || die "PROXY_SERVER_IP must be set for proxy-client"

    log "starting proxy client on ${PROXY_CLIENT_LISTEN_ADDR}:${PROXY_HTTP_PORT} -> socks5://${PROXY_SERVER_IP}:${PROXY_SOCKS_PORT}"
    exec "$GOST_BIN" -C "$GOST_CONFIG"
}

main "$@"

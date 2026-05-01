#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"

load_config

EASYTIER_BIN="${EASYTIER_BIN:-easytier-core}"
EASYTIER_CONFIG="${EASYTIER_CONFIG:-/etc/home-netops/easytier-home.yaml}"

main() {
    need_cmd "$EASYTIER_BIN"
    [[ -f "$EASYTIER_CONFIG" ]] || die "EASYTIER_CONFIG not found: $EASYTIER_CONFIG"

    log "starting EasyTier with config: $EASYTIER_CONFIG"
    exec "$EASYTIER_BIN" --config-file "$EASYTIER_CONFIG"
}

main "$@"

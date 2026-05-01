#!/usr/bin/env bash

HOME_NETOPS_CONFIG="${HOME_NETOPS_CONFIG:-/etc/home-netops/home-netops.conf}"

log() {
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    printf '[%s] %s\n' "$ts" "$*"
}

die() {
    log "ERROR: $*" >&2
    exit 1
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

load_config() {
    if [[ -f "$HOME_NETOPS_CONFIG" ]]; then
        # shellcheck disable=SC1090
        source "$HOME_NETOPS_CONFIG"
    fi
}

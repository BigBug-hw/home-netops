#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"

load_config

CLOUD_HOST="${CLOUD_HOST:-}"
CLOUD_USER="${CLOUD_USER:-root}"
CLOUD_PORT="${CLOUD_PORT:-22}"
REMOTE_BIND_ADDR="${REMOTE_BIND_ADDR:-127.0.0.1}"
REMOTE_BIND_PORT="${REMOTE_BIND_PORT:-2222}"
LOCAL_TARGET_HOST="${LOCAL_TARGET_HOST:-127.0.0.1}"
LOCAL_TARGET_PORT="${LOCAL_TARGET_PORT:-22}"
IDENTITY_FILE="${IDENTITY_FILE:-}"
AUTOSSH_BIN="${AUTOSSH_BIN:-autossh}"
CHECK_LOCAL_SSHD="${CHECK_LOCAL_SSHD:-1}"

main() {
    need_cmd "$AUTOSSH_BIN"
    [[ -n "$CLOUD_HOST" ]] || die "CLOUD_HOST must be set in $HOME_NETOPS_CONFIG"

    if [[ "$CHECK_LOCAL_SSHD" == "1" ]]; then
        need_cmd ss
        if ! ss -lnt | awk '{print $4}' | grep -qE '(^|:)'"${LOCAL_TARGET_PORT}"'$'; then
            die "local sshd does not seem to be listening on port ${LOCAL_TARGET_PORT}"
        fi
    fi

    local ssh_opts=(
        -p "$CLOUD_PORT"
        -o "ServerAliveInterval=30"
        -o "ServerAliveCountMax=3"
        -o "ExitOnForwardFailure=yes"
        -o "StrictHostKeyChecking=accept-new"
    )

    if [[ -n "$IDENTITY_FILE" ]]; then
        ssh_opts+=(-i "$IDENTITY_FILE")
    fi

    export AUTOSSH_GATETIME=0
    export AUTOSSH_PORT=0

    log "starting reverse SSH ${REMOTE_BIND_ADDR}:${REMOTE_BIND_PORT} -> ${LOCAL_TARGET_HOST}:${LOCAL_TARGET_PORT} via ${CLOUD_USER}@${CLOUD_HOST}:${CLOUD_PORT}"
    exec "$AUTOSSH_BIN" -M 0 -N \
        "${ssh_opts[@]}" \
        -R "${REMOTE_BIND_ADDR}:${REMOTE_BIND_PORT}:${LOCAL_TARGET_HOST}:${LOCAL_TARGET_PORT}" \
        "${CLOUD_USER}@${CLOUD_HOST}"
}

main "$@"

#!/usr/bin/env bash
set -euo pipefail

CLOUD_HOST="82.156.118.129"
CLOUD_USER="root"
CLOUD_PORT="22"

REMOTE_BIND_ADDR="127.0.0.1"
REMOTE_BIND_PORT="2222"

LOCAL_TARGET_HOST="127.0.0.1"
LOCAL_TARGET_PORT="22"

IDENTITY_FILE=""

AUTOSSH_BIN="/usr/bin/autossh"
LOG_FILE="/home/renyq/software/aiagent/autossh-reverse-tunnel.log"
PID_FILE="/home/renyq/software/aiagent/autossh-reverse-tunnel.pid"

if [[ ! -x "$AUTOSSH_BIN" ]]; then
    echo "ERROR: autossh not found: $AUTOSSH_BIN" >&2
    exit 1
fi

if ! ss -lnt | awk '{print $4}' | grep -qE '(^|:)'"${LOCAL_TARGET_PORT}"'$'; then
    echo "ERROR: local sshd does not seem to be listening on port ${LOCAL_TARGET_PORT}" >&2
    exit 2
fi

if [[ -f "$PID_FILE" ]]; then
    old_pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    if [[ -n "${old_pid:-}" ]] && kill -0 "$old_pid" 2>/dev/null; then
        echo "autossh already running, pid=$old_pid"
        exit 0
    else
        rm -f "$PID_FILE"
    fi
fi

SSH_OPTS=(
    -p "$CLOUD_PORT"
    -o "ServerAliveInterval=30"
    -o "ServerAliveCountMax=3"
    -o "ExitOnForwardFailure=yes"
    -o "StrictHostKeyChecking=accept-new"
)

if [[ -n "$IDENTITY_FILE" ]]; then
    SSH_OPTS+=(-i "$IDENTITY_FILE")
fi

export AUTOSSH_GATETIME=0
export AUTOSSH_PORT=0

mkdir -p "$(dirname "$LOG_FILE")"
mkdir -p "$(dirname "$PID_FILE")"

nohup "$AUTOSSH_BIN" -M 0 -N \
    "${SSH_OPTS[@]}" \
    -R "${REMOTE_BIND_ADDR}:${REMOTE_BIND_PORT}:${LOCAL_TARGET_HOST}:${LOCAL_TARGET_PORT}" \
    "${CLOUD_USER}@${CLOUD_HOST}" \
    >>"$LOG_FILE" 2>&1 &

pid=$!
echo "$pid" > "$PID_FILE"

sleep 1
if kill -0 "$pid" 2>/dev/null; then
    echo "autossh started in background, pid=$pid"
    exit 0
else
    echo "ERROR: autossh failed to start, check $LOG_FILE" >&2
    rm -f "$PID_FILE"
    exit 3
fi

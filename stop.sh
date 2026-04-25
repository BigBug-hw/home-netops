#!/usr/bin/env bash
set -euo pipefail

PID_FILE="/home/renyq/software/aiagent/autossh-reverse-tunnel.pid"

if [[ ! -f "$PID_FILE" ]]; then
    echo "autossh not running"
    exit 0
fi

pid="$(cat "$PID_FILE" 2>/dev/null || true)"

if [[ -z "${pid:-}" ]]; then
    rm -f "$PID_FILE"
    echo "invalid pid file, removed"
    exit 0
fi

if kill -0 "$pid" 2>/dev/null; then
    kill "$pid"
    sleep 1
    if kill -0 "$pid" 2>/dev/null; then
        kill -9 "$pid" 2>/dev/null || true
    fi
    echo "autossh stopped, pid=$pid"
else
    echo "process not running, cleaning pid file"
fi

rm -f "$PID_FILE"

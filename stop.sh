#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "ERROR: stop.sh controls a system service and must run as root" >&2
    exit 1
fi

systemctl stop home-netops-reverse-ssh.service

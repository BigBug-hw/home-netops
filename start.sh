#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "ERROR: start.sh controls a system service and must run as root" >&2
    exit 1
fi

systemctl start home-netops-reverse-ssh.service

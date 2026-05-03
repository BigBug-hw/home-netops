#!/usr/bin/env bash
set -euo pipefail

SYSTEMD_DIR="${HOME_NETOPS_SYSTEMD_DIR:-/etc/systemd/system}"
SYSTEMCTL="${HOME_NETOPS_SYSTEMCTL:-systemctl}"
YES=0

usage() {
    cat <<USAGE
Usage: sudo ./uninstall.sh [--yes]

Options:
  --yes   Do not prompt before removing home-netops systemd units.
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --yes|-y)
            YES=1
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --purge)
            echo "ERROR: --purge is not supported; scripts and config stay in APP_HOME" >&2
            usage >&2
            exit 2
            ;;
        *)
            echo "ERROR: unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
    shift
done

if [[ "${HOME_NETOPS_ALLOW_NON_ROOT:-0}" != "1" && "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "ERROR: uninstall.sh must run as root" >&2
    exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

if [[ "$YES" != "1" && -t 0 ]]; then
    read -r -p "Remove home-netops systemd units from $SYSTEMD_DIR? [y/N] " answer
    case "$answer" in
        y|Y|yes|YES)
            ;;
        *)
            echo "cancelled"
            exit 1
            ;;
    esac
fi

units=(
    home-netops-proxy-client.service
    home-netops-proxy-server.service
    home-netops-easytier.service
    home-netops-reverse-ssh.service
    home-netops-aliyun-firewall.timer
    home-netops-aliyun-firewall.service
    home-netops-tencent-firewall.timer
    home-netops-tencent-firewall.service
    home-netops-aliyun-ddns.timer
    home-netops-aliyun-ddns.service
)

for unit in "${units[@]}"; do
    "$SYSTEMCTL" disable --now "$unit" >/dev/null 2>&1 || true
done

for unit in "${units[@]}"; do
    rm -f "$SYSTEMD_DIR/$unit"
done

"$SYSTEMCTL" daemon-reload

bashrc="$(proxy_client_bashrc_path)"
remove_proxy_client_block "$bashrc"

echo "home-netops systemd units and proxy-client shell config removed"

#!/usr/bin/env bash
set -euo pipefail

PROJECT_NAME="home-netops"
PREFIX="${PREFIX:-/usr/local}"
LIB_DIR="${HOME_NETOPS_LIB_DIR:-$PREFIX/lib/$PROJECT_NAME}"
ETC_DIR="${HOME_NETOPS_ETC_DIR:-/etc/$PROJECT_NAME}"
SYSTEMD_DIR="${HOME_NETOPS_SYSTEMD_DIR:-/etc/systemd/system}"
SYSTEMCTL="${HOME_NETOPS_SYSTEMCTL:-systemctl}"
PURGE=0
YES=0

usage() {
    cat <<USAGE
Usage: sudo ./uninstall.sh [--purge] [--yes]

Options:
  --purge   Remove $ETC_DIR after services and program files are removed.
  --yes     Do not prompt. Without --purge, config is still preserved.
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --purge)
            PURGE=1
            ;;
        --yes|-y)
            YES=1
            ;;
        -h|--help)
            usage
            exit 0
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

units=(
    home-netops-proxy-server.service
    home-netops-reverse-ssh.service
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

rm -rf "$LIB_DIR"
"$SYSTEMCTL" daemon-reload

if [[ "$PURGE" != "1" && "$YES" != "1" && -t 0 && -d "$ETC_DIR" ]]; then
    read -r -p "Remove config directory $ETC_DIR? [y/N] " answer
    case "$answer" in
        y|Y|yes|YES)
            PURGE=1
            ;;
    esac
fi

if [[ "$PURGE" == "1" ]]; then
    rm -rf "$ETC_DIR"
    echo "removed config: $ETC_DIR"
else
    echo "kept config: $ETC_DIR"
fi

echo "home-netops uninstalled"

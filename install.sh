#!/usr/bin/env bash
set -euo pipefail

PROJECT_NAME="home-netops"
PREFIX="${PREFIX:-/usr/local}"
LIB_DIR="${HOME_NETOPS_LIB_DIR:-$PREFIX/lib/$PROJECT_NAME}"
ETC_DIR="${HOME_NETOPS_ETC_DIR:-/etc/$PROJECT_NAME}"
CONFIG_FILE="${HOME_NETOPS_CONFIG:-$ETC_DIR/$PROJECT_NAME.conf}"
SYSTEMD_DIR="${HOME_NETOPS_SYSTEMD_DIR:-/etc/systemd/system}"
SYSTEMCTL="${HOME_NETOPS_SYSTEMCTL:-systemctl}"
START_SERVICES=1

usage() {
    cat <<USAGE
Usage: sudo ./install.sh [--no-start]

Options:
  --no-start   Install files and reload systemd without enabling or starting services.
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-start)
            START_SERVICES=0
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
    echo "ERROR: install.sh must run as root" >&2
    exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
scripts=(
    lib/common.sh
    lib/get-public-ip.sh
    ddns/aliyun.sh
    firewall/tencent.sh
    reverse-ssh.sh
)
units=(
    home-netops-aliyun-ddns.service
    home-netops-aliyun-ddns.timer
    home-netops-tencent-firewall.service
    home-netops-tencent-firewall.timer
    home-netops-reverse-ssh.service
)

for script in "${scripts[@]}" install.sh uninstall.sh; do
    bash -n "$SCRIPT_DIR/$script"
done

install -d -m 0755 "$LIB_DIR" "$LIB_DIR/ddns" "$LIB_DIR/firewall" "$LIB_DIR/lib" "$ETC_DIR" "$SYSTEMD_DIR"
for script in "${scripts[@]}"; do
    install -m 0755 "$SCRIPT_DIR/$script" "$LIB_DIR/$script"
done

if [[ ! -f "$CONFIG_FILE" ]]; then
    install -m 0600 "$SCRIPT_DIR/config/home-netops.conf.example" "$CONFIG_FILE"
    echo "created config: $CONFIG_FILE"
else
    echo "kept existing config: $CONFIG_FILE"
fi

for unit in "${units[@]}"; do
    install -m 0644 "$SCRIPT_DIR/systemd/$unit" "$SYSTEMD_DIR/$unit"
done

"$SYSTEMCTL" daemon-reload

if [[ "$START_SERVICES" == "1" ]]; then
    "$SYSTEMCTL" enable --now home-netops-aliyun-ddns.timer
    "$SYSTEMCTL" enable --now home-netops-tencent-firewall.timer
    "$SYSTEMCTL" enable --now home-netops-reverse-ssh.service
fi

echo "home-netops installed"

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
SERVICES=""
INTERACTIVE=0

usage() {
    cat <<USAGE
Usage: sudo ./install.sh --services LIST [--no-start]
       sudo ./install.sh --interactive [--no-start]

Options:
  --services LIST
               Comma-separated services to install: all, ddns, firewall, reverse-ssh.
               Required for non-interactive use. reverse-ssh requires firewall.
  --interactive
               Prompt for services instead of reading --services.
  --no-start   Install files and reload systemd without enabling or starting services.
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --services)
            [[ $# -ge 2 ]] || {
                echo "ERROR: --services requires a value" >&2
                usage >&2
                exit 2
            }
            SERVICES="$2"
            shift
            ;;
        --services=*)
            SERVICES="${1#*=}"
            ;;
        --interactive)
            INTERACTIVE=1
            ;;
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
selected_services=()
units=()
enable_units=()
scripts=(
    lib/common.sh
    lib/get-public-ip.sh
    lib/reverse-ssh.sh
    ddns/aliyun.sh
    firewall/tencent.sh
)

has_service() {
    local service="$1" selected

    for selected in "${selected_services[@]}"; do
        [[ "$selected" == "$service" ]] && return 0
    done
    return 1
}

prompt_services() {
    printf 'Select services to install (all, ddns, firewall, reverse-ssh).\n' >&2
    printf 'Use comma-separated names, for example: ddns,firewall\n' >&2
    printf 'Note: reverse-ssh requires firewall.\n' >&2
    printf 'Services: ' >&2
    read -r SERVICES
}

parse_services() {
    local raw_items item

    if [[ -z "$SERVICES" ]]; then
        if [[ "$INTERACTIVE" == "1" || -t 0 ]]; then
            prompt_services
        else
            echo "ERROR: install scope is required. Use --services LIST or --interactive." >&2
            usage >&2
            exit 2
        fi
    fi

    SERVICES="${SERVICES//[[:space:]]/}"
    if [[ -z "$SERVICES" ]]; then
        echo "ERROR: install scope is required; no default service is selected." >&2
        exit 2
    fi

    if [[ "$SERVICES" == "all" ]]; then
        selected_services=(ddns firewall reverse-ssh)
        return
    fi

    IFS=',' read -ra raw_items <<< "$SERVICES"
    for item in "${raw_items[@]}"; do
        case "$item" in
            ddns|firewall|reverse-ssh)
                selected_services+=("$item")
                ;;
            all)
                echo "ERROR: all must be used by itself." >&2
                exit 2
                ;;
            "")
                echo "ERROR: empty service name in --services." >&2
                exit 2
                ;;
            *)
                echo "ERROR: unknown service: $item" >&2
                usage >&2
                exit 2
                ;;
        esac
    done

    if has_service reverse-ssh && ! has_service firewall; then
        echo "ERROR: reverse-ssh requires firewall. Use --services firewall,reverse-ssh." >&2
        exit 2
    fi
}

select_units() {
    if has_service ddns; then
        units+=(home-netops-aliyun-ddns.service home-netops-aliyun-ddns.timer)
        enable_units+=(home-netops-aliyun-ddns.timer)
    fi

    if has_service firewall; then
        units+=(home-netops-tencent-firewall.service home-netops-tencent-firewall.timer)
        enable_units+=(home-netops-tencent-firewall.timer)
    fi

    if has_service reverse-ssh; then
        units+=(home-netops-reverse-ssh.service)
        enable_units+=(home-netops-reverse-ssh.service)
    fi
}

parse_services
select_units

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
    for unit in "${enable_units[@]}"; do
        "$SYSTEMCTL" enable --now "$unit"
    done
fi

echo "home-netops installed: ${selected_services[*]}"

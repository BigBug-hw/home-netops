#!/usr/bin/env bash
set -euo pipefail

SYSTEMD_DIR="${HOME_NETOPS_SYSTEMD_DIR:-/etc/systemd/system}"
SYSTEMCTL="${HOME_NETOPS_SYSTEMCTL:-systemctl}"
START_SERVICES=1
ROLE=""
CONFIG=""
APP_HOME=""

usage() {
    cat <<USAGE
Usage: sudo ./install.sh --role ROLE --config FILE [--app-home DIR] [--no-start]

Options:
  --role ROLE     Role to install from config: home, ali, or tencent.
  --config FILE   JSON config file defining roles, services, and variables.
  --app-home DIR  Application directory. Defaults to this repository directory.
  --no-start      Install units and reload systemd without enabling or starting services.
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --role)
            [[ $# -ge 2 ]] || {
                echo "ERROR: --role requires a value" >&2
                usage >&2
                exit 2
            }
            ROLE="$2"
            shift
            ;;
        --role=*)
            ROLE="${1#*=}"
            ;;
        --config)
            [[ $# -ge 2 ]] || {
                echo "ERROR: --config requires a value" >&2
                usage >&2
                exit 2
            }
            CONFIG="$2"
            shift
            ;;
        --config=*)
            CONFIG="${1#*=}"
            ;;
        --app-home)
            [[ $# -ge 2 ]] || {
                echo "ERROR: --app-home requires a value" >&2
                usage >&2
                exit 2
            }
            APP_HOME="$2"
            shift
            ;;
        --app-home=*)
            APP_HOME="${1#*=}"
            ;;
        --no-start)
            START_SERVICES=0
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --services|--services=*|--interactive)
            echo "ERROR: $1 is not supported; services are defined in the JSON role config" >&2
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
    echo "ERROR: install.sh must run as root" >&2
    exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APP_HOME="${APP_HOME:-$SCRIPT_DIR}"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

[[ -n "$ROLE" ]] || die "--role is required"
[[ -n "$CONFIG" ]] || die "--config is required"
APP_HOME="$(cd -- "$APP_HOME" && pwd)"
CONFIG="$(cd -- "$(dirname -- "$CONFIG")" && pwd)/$(basename -- "$CONFIG")"

HOME_NETOPS_ROLE="$ROLE"
HOME_NETOPS_CONFIG="$CONFIG"
HOME_NETOPS_APP_HOME="$APP_HOME"
load_config

scripts=(
    lib/common.sh
    lib/easytier.sh
    lib/get-public-ip.sh
    lib/proxy-client.sh
    lib/proxy-server.sh
    lib/reverse-ssh.sh
    ddns/aliyun.sh
    firewall/tencent.sh
    install.sh
    uninstall.sh
    check.sh
)

for script in "${scripts[@]}"; do
    [[ -f "$APP_HOME/$script" ]] || die "missing app file: $APP_HOME/$script"
    bash -n "$APP_HOME/$script"
done

unit_for_service() {
    case "$1" in
        ddns)
            printf '%s\n' home-netops-aliyun-ddns.service home-netops-aliyun-ddns.timer
            ;;
        firewall)
            printf '%s\n' home-netops-tencent-firewall.service home-netops-tencent-firewall.timer
            ;;
        reverse-ssh)
            printf '%s\n' home-netops-reverse-ssh.service
            ;;
        easytier)
            printf '%s\n' home-netops-easytier.service
            ;;
        proxy-server)
            printf '%s\n' home-netops-proxy-server.service
            ;;
        proxy-client)
            printf '%s\n' home-netops-proxy-client.service
            ;;
    esac
}

enable_unit_for_service() {
    case "$1" in
        ddns)
            printf '%s\n' home-netops-aliyun-ddns.timer
            ;;
        firewall)
            printf '%s\n' home-netops-tencent-firewall.timer
            ;;
        reverse-ssh)
            printf '%s\n' home-netops-reverse-ssh.service
            ;;
        easytier)
            printf '%s\n' home-netops-easytier.service
            ;;
        proxy-server)
            printf '%s\n' home-netops-proxy-server.service
            ;;
        proxy-client)
            printf '%s\n' home-netops-proxy-client.service
            ;;
    esac
}

unit_env() {
    cat <<UNIT
Environment=HOME_NETOPS_ROLE=$ROLE
Environment=HOME_NETOPS_CONFIG=$CONFIG
Environment=HOME_NETOPS_APP_HOME=$APP_HOME
UNIT
}

write_service_unit() {
    local unit="$1" description="$2" exec_start="$3" type="$4" requires="${5:-}" after_extra="${6:-}"
    local target="$SYSTEMD_DIR/$unit"

    {
        printf '[Unit]\n'
        printf 'Description=%s\n' "$description"
        printf 'After=network-online.target'
        [[ -n "$after_extra" ]] && printf ' %s' "$after_extra"
        printf '\n'
        printf 'Wants=network-online.target\n'
        [[ -n "$requires" ]] && printf 'Requires=%s\n' "$requires"
        printf '\n[Service]\n'
        printf 'Type=%s\n' "$type"
        printf 'User=root\nGroup=root\n'
        unit_env
        printf 'ExecStart=%s\n' "$exec_start"
        if [[ "$type" == "simple" ]]; then
            printf 'Restart=always\nRestartSec=5\n'
        fi
        if [[ "$type" == "simple" ]]; then
            printf '\n[Install]\nWantedBy=multi-user.target\n'
        fi
    } > "$target"
    chmod 0644 "$target"
}

write_timer_unit() {
    local unit="$1" description="$2" service_unit="$3"
    local target="$SYSTEMD_DIR/$unit"

    cat > "$target" <<UNIT
[Unit]
Description=$description

[Timer]
OnBootSec=30s
OnUnitActiveSec=10min
AccuracySec=30s
Persistent=true
Unit=$service_unit

[Install]
WantedBy=timers.target
UNIT
    chmod 0644 "$target"
}

write_units_for_service() {
    local service="$1"

    case "$service" in
        ddns)
            write_service_unit \
                home-netops-aliyun-ddns.service \
                "home-netops Aliyun DDNS update" \
                "$APP_HOME/ddns/aliyun.sh" \
                oneshot
            write_timer_unit \
                home-netops-aliyun-ddns.timer \
                "Run home-netops Aliyun DDNS update periodically" \
                home-netops-aliyun-ddns.service
            ;;
        firewall)
            write_service_unit \
                home-netops-tencent-firewall.service \
                "home-netops Tencent firewall update" \
                "$APP_HOME/firewall/tencent.sh" \
                oneshot
            write_timer_unit \
                home-netops-tencent-firewall.timer \
                "Run home-netops Tencent firewall update periodically" \
                home-netops-tencent-firewall.service
            ;;
        reverse-ssh)
            write_service_unit \
                home-netops-reverse-ssh.service \
                "home-netops reverse SSH tunnel" \
                "$APP_HOME/lib/reverse-ssh.sh" \
                simple \
                home-netops-tencent-firewall.service \
                home-netops-tencent-firewall.service
            ;;
        easytier)
            if has_item firewall "${HOME_NETOPS_SERVICES[@]}"; then
                write_service_unit \
                    home-netops-easytier.service \
                    "home-netops EasyTier node" \
                    "$APP_HOME/lib/easytier.sh" \
                    simple \
                    home-netops-tencent-firewall.service \
                    home-netops-tencent-firewall.service
            else
                write_service_unit \
                    home-netops-easytier.service \
                    "home-netops EasyTier node" \
                    "$APP_HOME/lib/easytier.sh" \
                    simple
            fi
            ;;
        proxy-server)
            write_service_unit \
                home-netops-proxy-server.service \
                "home-netops proxy server on EasyTier network" \
                "$APP_HOME/lib/proxy-server.sh" \
                simple \
                home-netops-easytier.service \
                home-netops-easytier.service
            ;;
        proxy-client)
            write_service_unit \
                home-netops-proxy-client.service \
                "home-netops local proxy client" \
                "$APP_HOME/lib/proxy-client.sh" \
                simple
            ;;
    esac
}

install_proxy_client() {
    local bashrc

    [[ -n "${PROXY_SERVER_IP:-}" ]] || die "PROXY_SERVER_IP must be set for proxy-client"
    PROXY_SOCKS_PORT="${PROXY_SOCKS_PORT:-1080}"
    PROXY_HTTP_PORT="${PROXY_HTTP_PORT:-8080}"
    PROXY_CLIENT_LISTEN_ADDR="${PROXY_CLIENT_LISTEN_ADDR:-127.0.0.1}"

    bashrc="$(proxy_client_bashrc_path)"
    install -d -m 0755 "$(dirname -- "$bashrc")"
    touch "$bashrc"
    remove_proxy_client_block "$bashrc"
    {
        printf '\n'
        proxy_client_block "$PROXY_CLIENT_LISTEN_ADDR" "$PROXY_HTTP_PORT"
    } >> "$bashrc"
    echo "home-netops proxy-client configured: $bashrc"
}

install -d -m 0755 "$SYSTEMD_DIR"

units=()
enable_units=()
for service in "${HOME_NETOPS_SERVICES[@]}"; do
    write_units_for_service "$service"
    while IFS= read -r unit; do
        units+=("$unit")
    done < <(unit_for_service "$service")
    while IFS= read -r unit; do
        enable_units+=("$unit")
    done < <(enable_unit_for_service "$service")
done

if has_item proxy-client "${HOME_NETOPS_SERVICES[@]}"; then
    install_proxy_client
fi

"$SYSTEMCTL" daemon-reload

if [[ "$START_SERVICES" == "1" ]]; then
    for unit in "${enable_units[@]}"; do
        "$SYSTEMCTL" enable --now "$unit"
    done
fi

echo "home-netops installed role=$ROLE services=${HOME_NETOPS_SERVICES[*]}"

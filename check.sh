#!/usr/bin/env bash
set -euo pipefail

SYSTEMD_DIR="${HOME_NETOPS_SYSTEMD_DIR:-/etc/systemd/system}"
SYSTEMCTL="${HOME_NETOPS_SYSTEMCTL:-systemctl}"
JOURNALCTL="${HOME_NETOPS_JOURNALCTL:-journalctl}"
ROLE=""
CONFIG=""
APP_HOME=""
FAILURES=0
DEEP=0
NO_NETWORK=0
SERVICE_FILTER=""
LOG_LINES=30

usage() {
    cat <<USAGE
Usage: ./check.sh --role ROLE --config FILE [--app-home DIR] [--deep] [--service SERVICE] [--logs N] [--no-network]

Options:
  --role ROLE     Role to check from config: home, ali, or tencent.
  --config FILE   JSON config file defining roles, services, and variables.
  --app-home DIR  Application directory. Defaults to this repository directory.
  --deep          Print service topology, unit details, recent logs, and read-only probes.
  --service NAME  Check only one enabled service from the selected role.
  --logs N        Recent journal lines to show per unit in --deep mode. Defaults to 30.
  --no-network    Skip TCP/HTTP connectivity probes in --deep mode.
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
        --deep)
            DEEP=1
            ;;
        --service)
            [[ $# -ge 2 ]] || {
                echo "ERROR: --service requires a value" >&2
                usage >&2
                exit 2
            }
            SERVICE_FILTER="$2"
            shift
            ;;
        --service=*)
            SERVICE_FILTER="${1#*=}"
            ;;
        --logs)
            [[ $# -ge 2 ]] || {
                echo "ERROR: --logs requires a value" >&2
                usage >&2
                exit 2
            }
            LOG_LINES="$2"
            shift
            ;;
        --logs=*)
            LOG_LINES="${1#*=}"
            ;;
        --no-network)
            NO_NETWORK=1
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

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APP_HOME="${APP_HOME:-$SCRIPT_DIR}"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

pass() {
    if [[ "$DEEP" == "1" ]]; then
        printf '  [OK] %s\n' "$*"
        return
    fi
    printf 'PASS %s\n' "$*"
}

info() {
    if [[ "$DEEP" == "1" ]]; then
        printf '  - %s\n' "$*"
        return
    fi
    printf 'INFO %s\n' "$*"
}

section() {
    [[ "$DEEP" == "1" ]] || return 0
    printf '\n== %s ==\n' "$*"
}

fail_check() {
    if [[ "$DEEP" == "1" ]]; then
        printf '  [FAIL] %s\n' "$*"
    else
        printf 'FAIL %s\n' "$*" >&2
    fi
    FAILURES=$((FAILURES + 1))
}

check_cmd() {
    if command -v "$1" >/dev/null 2>&1; then
        pass "command $1"
    else
        fail_check "missing command $1"
    fi
}

check_file() {
    if [[ -e "$1" ]]; then
        pass "file $1"
    else
        fail_check "missing file $1"
    fi
}

check_json_array() {
    local name="$1" value="$2"

    if jq -e 'type == "array" and length > 0' >/dev/null 2>&1 <<< "$value"; then
        pass "$name JSON array"
    else
        fail_check "$name must be a non-empty JSON array"
    fi
}

check_unit() {
    local unit="$1"
    local unit_path="$SYSTEMD_DIR/$unit"

    check_file "$unit_path"
    if "$SYSTEMCTL" is-enabled "$unit" >/dev/null 2>&1; then
        pass "enabled $unit"
    else
        fail_check "not enabled $unit"
    fi
    if "$SYSTEMCTL" is-active "$unit" >/dev/null 2>&1; then
        pass "active $unit"
    else
        fail_check "not active $unit"
    fi
}

unit_state() {
    local unit="$1"
    local enabled active failed

    enabled="$("$SYSTEMCTL" is-enabled "$unit" 2>/dev/null || true)"
    active="$("$SYSTEMCTL" is-active "$unit" 2>/dev/null || true)"
    failed="$("$SYSTEMCTL" is-failed "$unit" 2>/dev/null || true)"
    info "unit $unit enabled=${enabled:-unknown} active=${active:-unknown} failed=${failed:-unknown}"
}

unit_logs() {
    local unit="$1"

    command -v "$JOURNALCTL" >/dev/null 2>&1 || {
        info "journal unavailable for $unit: missing command $JOURNALCTL"
        return 0
    }

    info "logs: $unit (last $LOG_LINES)"
    "$JOURNALCTL" -u "$unit" -n "$LOG_LINES" --no-pager 2>/dev/null \
        | sed 's/^/      /' \
        || info "journal read failed for $unit"
}

unit_needs_logs() {
    local service="$1" unit="$2" active failed

    [[ -e "$SYSTEMD_DIR/$unit" ]] || return 0

    if failed="$("$SYSTEMCTL" is-failed "$unit" 2>/dev/null)"; then
        [[ "$failed" == "failed" || -z "$failed" ]] && return 0
    fi

    case "$unit" in
        *.timer)
            "$SYSTEMCTL" is-active "$unit" >/dev/null 2>&1 || return 0
            ;;
        *.service)
            case "$service" in
                reverse-ssh|easytier|proxy-server|proxy-client)
                    "$SYSTEMCTL" is-active "$unit" >/dev/null 2>&1 || return 0
                    ;;
            esac
            ;;
    esac

    return 1
}

tcp_probe() {
    local host="$1" port="$2" label="$3"

    if [[ "$NO_NETWORK" == "1" ]]; then
        info "skip network probe $label ${host}:${port}"
        return 0
    fi

    if [[ -z "$host" || -z "$port" ]]; then
        fail_check "network probe $label missing host or port"
        return 0
    fi

    if command -v timeout >/dev/null 2>&1; then
        if timeout 3 bash -c ':</dev/tcp/"$1"/"$2"' _ "$host" "$port" >/dev/null 2>&1; then
            pass "tcp $label ${host}:${port}"
        else
            fail_check "tcp $label unreachable: ${host}:${port}"
        fi
    else
        info "skip network probe $label ${host}:${port}: missing timeout"
    fi
}

firewall_provider_for_service() {
    case "$1" in
        aliyun-firewall)
            printf '%s\n' aliyun
            ;;
        tencent-firewall)
            printf '%s\n' tencent
            ;;
        firewall)
            printf '%s\n' "${FIREWALL_PROVIDER:-tencent}"
            ;;
    esac
}

firewall_timer_unit() {
    printf 'home-netops-%s-firewall.timer\n' "$(firewall_provider_for_service "$1")"
}

firewall_service_unit() {
    printf 'home-netops-%s-firewall.service\n' "$(firewall_provider_for_service "$1")"
}

units_for_service() {
    case "$1" in
        ddns)
            printf '%s\n' home-netops-aliyun-ddns.timer home-netops-aliyun-ddns.service
            ;;
        firewall|tencent-firewall|aliyun-firewall)
            printf '%s\n' "$(firewall_timer_unit "$1")" "$(firewall_service_unit "$1")"
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

primary_unit_for_service() {
    case "$1" in
        ddns)
            printf '%s\n' home-netops-aliyun-ddns.timer
            ;;
        firewall|tencent-firewall|aliyun-firewall)
            firewall_timer_unit "$1"
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

service_dependencies() {
    case "$1" in
        reverse-ssh)
            firewall_dependency_services
            ;;
        easytier)
            firewall_dependency_services
            ;;
        proxy-server)
            printf '%s\n' easytier
            ;;
    esac
}

firewall_dependency_services() {
    local service

    for service in "${HOME_NETOPS_SERVICES[@]}"; do
        case "$service" in
            firewall|tencent-firewall|aliyun-firewall)
                printf '%s\n' "$service"
                ;;
        esac
    done
}

selected_services() {
    local service

    if [[ -n "$SERVICE_FILTER" ]]; then
        printf '%s\n' "$SERVICE_FILTER"
        return
    fi

    for service in "${HOME_NETOPS_SERVICES[@]}"; do
        printf '%s\n' "$service"
    done
}

print_topology() {
    local service deps units

    section "Topology"
    info "role: $ROLE"
    info "services: ${HOME_NETOPS_SERVICES[*]}"
    while IFS= read -r service; do
        [[ -n "$service" ]] || continue
        deps="$(service_dependencies "$service" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
        units="$(units_for_service "$service" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
        info "$service -> deps: ${deps:-none}; units: $units"
    done < <(selected_services)
}

deep_units_for_service() {
    local service="$1" unit

    while IFS= read -r unit; do
        [[ -n "$unit" ]] || continue
        check_file "$SYSTEMD_DIR/$unit"
        unit_state "$unit"
        if unit_needs_logs "$service" "$unit"; then
            unit_logs "$unit"
        else
            info "logs: $unit skipped because unit is OK"
        fi
    done < <(units_for_service "$service")
}

check_easytier_config_placeholders() {
    local config="$1"

    [[ -f "$config" ]] || return 0
    if grep -q 'REPLACE_WITH_ROTATED' "$config"; then
        fail_check "EasyTier config still contains rotated-secret placeholders: $config"
    else
        pass "EasyTier config secrets filled"
    fi
}

read_easytier_lan_ip() {
    local config="$1"

    awk -F '"' '/^[[:space:]]*ipv4[[:space:]]*=/{print $2; exit}' "$config"
}

read_easytier_rpc_portal() {
    local config="$1"

    awk -F '"' '/^[[:space:]]*rpc_portal[[:space:]]*=/{print $2; exit}' "$config"
}

deep_service() {
    local service="$1" unit easytier_config easytier_ip rpc_portal rpc_host rpc_port

    section "Service: $service"
    deep_units_for_service "$service"

    case "$service" in
        ddns)
            info "ddns target ${ALIYUN_RR:-home}.${ALIYUN_DOMAIN_NAME:-bigbug.ren} type=${ALIYUN_TYPE:-A} line=${ALIYUN_LINE:-default}"
            check_file "$(resolve_app_path "${GET_IP_SCRIPT:-lib/get-public-ip.sh}")"
            ;;
        firewall|tencent-firewall|aliyun-firewall)
            case "$(firewall_provider_for_service "$service")" in
                aliyun)
                    check_json_array ALIYUN_FIREWALL_RULES "${ALIYUN_FIREWALL_RULES:-}"
                    info "aliyun firewall instance=${ALIYUN_INSTANCE_ID:-} region=${ALIYUN_BIZ_REGION_ID:-}"
                    ;;
                tencent)
                    check_json_array TENCENT_FIREWALL_RULES "${TENCENT_FIREWALL_RULES:-}"
                    info "tencent firewall instance=${TENCENT_INSTANCE_ID:-} region=${TENCENT_REGION:-}"
                    ;;
            esac
            ;;
        reverse-ssh)
            tcp_probe "${LOCAL_TARGET_HOST:-127.0.0.1}" "${LOCAL_TARGET_PORT:-22}" reverse-ssh-local-target
            info "reverse ssh remote ${REMOTE_BIND_ADDR:-127.0.0.1}:${REMOTE_BIND_PORT:-2222} via ${CLOUD_USER:-root}@${CLOUD_HOST:-}:${CLOUD_PORT:-22}"
            ;;
        easytier)
            easytier_config="${EASYTIER_CONFIG:-config/easytier-$ROLE.yaml}"
            easytier_config="$(resolve_app_path "$easytier_config")"
            check_easytier_config_placeholders "$easytier_config"
            if [[ -f "$easytier_config" ]]; then
                rpc_portal="$(read_easytier_rpc_portal "$easytier_config")"
                if [[ "$rpc_portal" == *:* ]]; then
                    rpc_host="${rpc_portal%:*}"
                    rpc_port="${rpc_portal##*:}"
                    tcp_probe "$rpc_host" "$rpc_port" easytier-rpc
                fi
            fi
            ;;
        proxy-server)
            easytier_config="${EASYTIER_CONFIG:-config/easytier-$ROLE.yaml}"
            easytier_config="$(resolve_app_path "$easytier_config")"
            easytier_ip="${EASYTIER_LAN_IP:-}"
            if [[ -z "$easytier_ip" && -f "$easytier_config" ]]; then
                easytier_ip="$(read_easytier_lan_ip "$easytier_config")"
            fi
            tcp_probe "$easytier_ip" "${PROXY_SOCKS_PORT:-1080}" proxy-server-socks
            tcp_probe "$easytier_ip" "${PROXY_HTTP_PORT:-8080}" proxy-server-http
            ;;
        proxy-client)
            check_file "$(resolve_app_path "${GOST_CONFIG:-config/gost.yaml}")"
            tcp_probe "${PROXY_SERVER_IP:-}" "${PROXY_SOCKS_PORT:-1080}" proxy-client-upstream-socks
            tcp_probe "${PROXY_CLIENT_LISTEN_ADDR:-127.0.0.1}" "${PROXY_HTTP_PORT:-8080}" proxy-client-local-http
            ;;
    esac

    unit="$(primary_unit_for_service "$service")"
    info "next logs: journalctl -u $unit -f"
}

[[ -n "$ROLE" ]] || die "--role is required"
[[ -n "$CONFIG" ]] || die "--config is required"
if [[ -n "$SERVICE_FILTER" ]]; then
    validate_service_name "$SERVICE_FILTER" || die "unknown service: $SERVICE_FILTER"
fi
[[ "$LOG_LINES" =~ ^[0-9]+$ && "$LOG_LINES" -gt 0 ]] || die "--logs must be a positive integer"
APP_HOME="$(cd -- "$APP_HOME" && pwd)"
CONFIG="$(cd -- "$(dirname -- "$CONFIG")" && pwd)/$(basename -- "$CONFIG")"

export HOME_NETOPS_ROLE="$ROLE"
export HOME_NETOPS_CONFIG="$CONFIG"
export HOME_NETOPS_APP_HOME="$APP_HOME"

section "Preflight"
if command -v jq >/dev/null 2>&1; then
    pass "command jq"
else
    fail_check "missing command jq"
    exit 1
fi

if load_config; then
    pass "config role=$ROLE"
else
    exit 1
fi

if [[ -n "$SERVICE_FILTER" ]] && ! has_item "$SERVICE_FILTER" "${HOME_NETOPS_SERVICES[@]}"; then
    die "service $SERVICE_FILTER is not enabled for role $ROLE"
fi

check_cmd curl

if has_item ddns $(selected_services); then
    check_cmd "${ALIYUN_BIN:-aliyun}"
fi

while IFS= read -r service; do
    [[ -n "$service" ]] || continue
    case "$service" in
        firewall|tencent-firewall|aliyun-firewall)
            case "$(firewall_provider_for_service "$service")" in
                aliyun)
                    check_cmd "${ALIYUN_BIN:-aliyun}"
                    [[ -n "${ALIYUN_INSTANCE_ID:-}" ]] || fail_check "ALIYUN_INSTANCE_ID is empty"
                    [[ -n "${ALIYUN_BIZ_REGION_ID:-}" ]] || fail_check "ALIYUN_BIZ_REGION_ID is empty"
                    ;;
                tencent)
                    TCCLI_BIN="$(resolve_command_path "${TCCLI_BIN:-${HOME_NETOPS_APP_HOME}/.venv/bin/tccli}")"
                    check_cmd "$TCCLI_BIN"
                    [[ -n "${TENCENT_INSTANCE_ID:-}" ]] || fail_check "TENCENT_INSTANCE_ID is empty"
                    [[ -n "${TENCENT_REGION:-}" ]] || fail_check "TENCENT_REGION is empty"
                    ;;
                *)
                    fail_check "unsupported firewall provider for service $service: $(firewall_provider_for_service "$service")"
                    ;;
            esac
            ;;
    esac
done < <(selected_services)

if has_item reverse-ssh $(selected_services); then
    check_cmd "${AUTOSSH_BIN:-autossh}"
    [[ -n "${CLOUD_HOST:-}" ]] || fail_check "CLOUD_HOST is empty"
fi

if has_item easytier $(selected_services); then
    check_cmd "${EASYTIER_BIN:-easytier-core}"
    EASYTIER_CONFIG="${EASYTIER_CONFIG:-config/easytier-$ROLE.yaml}"
    EASYTIER_CONFIG="$(resolve_app_path "$EASYTIER_CONFIG")"
    check_file "$EASYTIER_CONFIG"
fi

if has_item proxy-server $(selected_services); then
    check_cmd "${GOST_BIN:-gost}"
fi

if has_item proxy-client $(selected_services); then
    check_cmd "${GOST_BIN:-gost}"
    [[ -n "${PROXY_SERVER_IP:-}" ]] || fail_check "PROXY_SERVER_IP is empty"
    [[ -n "${PROXY_SOCKS_PORT:-}" ]] || fail_check "PROXY_SOCKS_PORT is empty"
    [[ -n "${PROXY_HTTP_PORT:-}" ]] || fail_check "PROXY_HTTP_PORT is empty"
    PROXY_CLIENT_LISTEN_ADDR="${PROXY_CLIENT_LISTEN_ADDR:-127.0.0.1}"
    bashrc="$(proxy_client_bashrc_path)"
    check_file "$bashrc"
    if [[ -f "$bashrc" ]] \
        && grep -q '^# home-netops proxy-client start$' "$bashrc" \
        && grep -q "ALL_PROXY=http://${PROXY_CLIENT_LISTEN_ADDR}:${PROXY_HTTP_PORT}" "$bashrc" \
        && grep -q "all_proxy=http://${PROXY_CLIENT_LISTEN_ADDR}:${PROXY_HTTP_PORT}" "$bashrc" \
        && grep -q "HTTP_PROXY=http://${PROXY_CLIENT_LISTEN_ADDR}:${PROXY_HTTP_PORT}" "$bashrc" \
        && grep -q "HTTPS_PROXY=http://${PROXY_CLIENT_LISTEN_ADDR}:${PROXY_HTTP_PORT}" "$bashrc" \
        && grep -q "http_proxy=http://${PROXY_CLIENT_LISTEN_ADDR}:${PROXY_HTTP_PORT}" "$bashrc" \
        && grep -q "https_proxy=http://${PROXY_CLIENT_LISTEN_ADDR}:${PROXY_HTTP_PORT}" "$bashrc"; then
        pass "proxy-client bashrc block"
    else
        fail_check "proxy-client bashrc block missing or incomplete"
    fi
fi

section "Systemd"
while IFS= read -r service; do
    [[ -n "$service" ]] || continue
    case "$service" in
        ddns)
            check_unit home-netops-aliyun-ddns.timer
            ;;
        firewall|tencent-firewall|aliyun-firewall)
            check_unit "$(firewall_timer_unit "$service")"
            ;;
        reverse-ssh)
            check_unit home-netops-reverse-ssh.service
            ;;
        easytier)
            check_unit home-netops-easytier.service
            ;;
        proxy-server)
            check_unit home-netops-proxy-server.service
            ;;
        proxy-client)
            check_unit home-netops-proxy-client.service
            ;;
    esac
done < <(selected_services)

if [[ "$DEEP" == "1" ]]; then
    print_topology
    while IFS= read -r service; do
        [[ -n "$service" ]] || continue
        deep_service "$service"
    done < <(selected_services)
fi

if (( FAILURES > 0 )); then
    printf 'home-netops check failed: %d issue(s)\n' "$FAILURES" >&2
    exit 1
fi

printf 'home-netops check passed: role=%s services=%s\n' "$ROLE" "${HOME_NETOPS_SERVICES[*]}"

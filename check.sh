#!/usr/bin/env bash
set -euo pipefail

SYSTEMD_DIR="${HOME_NETOPS_SYSTEMD_DIR:-/etc/systemd/system}"
SYSTEMCTL="${HOME_NETOPS_SYSTEMCTL:-systemctl}"
ROLE=""
CONFIG=""
APP_HOME=""
FAILURES=0

usage() {
    cat <<USAGE
Usage: ./check.sh --role ROLE --config FILE [--app-home DIR]

Options:
  --role ROLE     Role to check from config: home, ali, or tencent.
  --config FILE   JSON config file defining roles, services, and variables.
  --app-home DIR  Application directory. Defaults to this repository directory.
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
    printf 'PASS %s\n' "$*"
}

fail_check() {
    printf 'FAIL %s\n' "$*" >&2
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

[[ -n "$ROLE" ]] || die "--role is required"
[[ -n "$CONFIG" ]] || die "--config is required"
APP_HOME="$(cd -- "$APP_HOME" && pwd)"
CONFIG="$(cd -- "$(dirname -- "$CONFIG")" && pwd)/$(basename -- "$CONFIG")"

export HOME_NETOPS_ROLE="$ROLE"
export HOME_NETOPS_CONFIG="$CONFIG"
export HOME_NETOPS_APP_HOME="$APP_HOME"

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

check_cmd curl

if has_item ddns "${HOME_NETOPS_SERVICES[@]}"; then
    check_cmd "${ALIYUN_BIN:-aliyun}"
fi

if has_item firewall "${HOME_NETOPS_SERVICES[@]}"; then
    TCCLI_BIN="$(resolve_command_path "${TCCLI_BIN:-${HOME_NETOPS_APP_HOME}/.venv/bin/tccli}")"
    check_cmd "$TCCLI_BIN"
    [[ -n "${TENCENT_INSTANCE_ID:-}" ]] || fail_check "TENCENT_INSTANCE_ID is empty"
    [[ -n "${TENCENT_REGION:-}" ]] || fail_check "TENCENT_REGION is empty"
fi

if has_item reverse-ssh "${HOME_NETOPS_SERVICES[@]}"; then
    check_cmd "${AUTOSSH_BIN:-autossh}"
    [[ -n "${CLOUD_HOST:-}" ]] || fail_check "CLOUD_HOST is empty"
fi

if has_item easytier "${HOME_NETOPS_SERVICES[@]}"; then
    check_cmd "${EASYTIER_BIN:-easytier-core}"
    EASYTIER_CONFIG="${EASYTIER_CONFIG:-config/easytier-$ROLE.yaml}"
    EASYTIER_CONFIG="$(resolve_app_path "$EASYTIER_CONFIG")"
    check_file "$EASYTIER_CONFIG"
fi

if has_item proxy-server "${HOME_NETOPS_SERVICES[@]}"; then
    check_cmd "${GOST_BIN:-gost}"
fi

for service in "${HOME_NETOPS_SERVICES[@]}"; do
    case "$service" in
        ddns)
            check_unit home-netops-aliyun-ddns.timer
            ;;
        firewall)
            check_unit home-netops-tencent-firewall.timer
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
    esac
done

if (( FAILURES > 0 )); then
    printf 'home-netops check failed: %d issue(s)\n' "$FAILURES" >&2
    exit 1
fi

printf 'home-netops check passed: role=%s services=%s\n' "$ROLE" "${HOME_NETOPS_SERVICES[*]}"

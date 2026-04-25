#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/home-netops-lib.sh"

load_config

SYSTEMCTL_BIN="${SYSTEMCTL_BIN:-systemctl}"
RESTART_REVERSE_AFTER_FIREWALL_CHANGE="${RESTART_REVERSE_AFTER_FIREWALL_CHANGE:-1}"

main() {
    local output

    if output="$("$SCRIPT_DIR/tencent_firewall.sh" 2>&1)"; then
        printf '%s\n' "$output"
    else
        printf '%s\n' "$output" >&2
        exit 1
    fi

    if [[ "$RESTART_REVERSE_AFTER_FIREWALL_CHANGE" == "1" ]] \
        && grep -q 'firewall_changed=1' <<< "$output" \
        && "$SYSTEMCTL_BIN" list-unit-files home-netops-reverse-ssh.service >/dev/null 2>&1; then
        "$SYSTEMCTL_BIN" try-restart home-netops-reverse-ssh.service
    fi
}

main "$@"

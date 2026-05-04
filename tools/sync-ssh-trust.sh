#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
HOSTS_FILE="$ROOT/config/deploy-hosts.json"
APPLY=0
ROLES=(home ali tencent)
KEY_NAME="home-netops_ed25519"
MARKER="home-netops ssh-trust"

usage() {
    cat <<USAGE
Usage: tools/sync-ssh-trust.sh [--dry-run|--apply] [options]

Options:
  --dry-run      Validate and print the trust plan only. This is the default.
  --apply        Generate new remote SSH keys and install mutual trust.
  --hosts FILE   Deployment host map. Defaults to config/deploy-hosts.json.
  --roles LIST   Space-separated roles. Defaults to: home ali tencent.
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)
            APPLY=0
            ;;
        --apply)
            APPLY=1
            ;;
        --hosts)
            [[ $# -ge 2 ]] || {
                echo "ERROR: --hosts requires a value" >&2
                exit 2
            }
            HOSTS_FILE="$2"
            shift
            ;;
        --hosts=*)
            HOSTS_FILE="${1#*=}"
            ;;
        --roles)
            [[ $# -ge 2 ]] || {
                echo "ERROR: --roles requires a value" >&2
                exit 2
            }
            read -r -a ROLES <<< "$2"
            shift
            ;;
        --roles=*)
            read -r -a ROLES <<< "${1#*=}"
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

die() {
    echo "ERROR: $*" >&2
    exit 1
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

shell_quote() {
    local value="$1"
    printf "'%s'" "${value//\'/\'\\\'\'}"
}

json_value() {
    local role="$1" key="$2"
    jq -r --arg role "$role" --arg key "$key" '.roles[$role][$key] // empty' "$HOSTS_FILE"
}

role_exists() {
    local role="$1"
    jq -e --arg role "$role" '.roles[$role] | type == "object"' "$HOSTS_FILE" >/dev/null
}

role_host() {
    json_value "$1" ssh_host
}

role_user() {
    local user
    user="$(json_value "$1" ssh_user)"
    printf '%s\n' "${user:-root}"
}

role_port() {
    local port
    port="$(json_value "$1" ssh_port)"
    printf '%s\n' "${port:-22}"
}

ssh_for_role() {
    local role="$1" command="$2"
    local host user port
    host="$(role_host "$role")"
    user="$(role_user "$role")"
    port="$(role_port "$role")"
    [[ -n "$host" ]] || die "missing ssh_host for role=$role in $HOSTS_FILE"
    ssh -p "$port" "${user}@${host}" "$command"
}

remote_generate_key() {
    local role="$1"
    local key_path="~/.ssh/$KEY_NAME"
    local comment="home-netops:ssh-trust:$role"

    ssh_for_role "$role" \
        "set -e; mkdir -p ~/.ssh; chmod 700 ~/.ssh; rm -f $key_path $key_path.pub; ssh-keygen -t ed25519 -N '' -f $key_path -C $(shell_quote "$comment") >/dev/null; chmod 600 $key_path; chmod 644 $key_path.pub"
}

remote_read_public_key() {
    local role="$1"
    ssh_for_role "$role" "cat ~/.ssh/$KEY_NAME.pub"
}

remove_managed_block_awk() {
    local start="$1" end="$2"
    printf 'awk %s' "$(shell_quote "/^$start\$/ {skip = 1; next} /^$end\$/ {skip = 0; next} !skip {print}")"
}

remote_install_trust() {
    local role="$1" auth_block="$2" config_block="$3"
    local auth_start="# $MARKER authorized_keys start"
    local auth_end="# $MARKER authorized_keys end"
    local config_start="# $MARKER config start"
    local config_end="# $MARKER config end"
    local auth_filter config_filter

    auth_filter="$(remove_managed_block_awk "$auth_start" "$auth_end")"
    config_filter="$(remove_managed_block_awk "$config_start" "$config_end")"

    ssh_for_role "$role" \
        "set -e; mkdir -p ~/.ssh; chmod 700 ~/.ssh; touch ~/.ssh/authorized_keys ~/.ssh/config; tmp_auth=\$(mktemp); tmp_config=\$(mktemp); $auth_filter ~/.ssh/authorized_keys > \"\$tmp_auth\"; cat \"\$tmp_auth\" > ~/.ssh/authorized_keys; rm -f \"\$tmp_auth\"; printf '%s\n' $(shell_quote "$auth_start") $(shell_quote "$auth_block") $(shell_quote "$auth_end") >> ~/.ssh/authorized_keys; $config_filter ~/.ssh/config > \"\$tmp_config\"; cat \"\$tmp_config\" > ~/.ssh/config; rm -f \"\$tmp_config\"; printf '%s\n' $(shell_quote "$config_start") $(shell_quote "$config_block") $(shell_quote "$config_end") >> ~/.ssh/config; chmod 600 ~/.ssh/authorized_keys ~/.ssh/config"
}

need_cmd jq
HOSTS_FILE="$(cd -- "$(dirname -- "$HOSTS_FILE")" && pwd)/$(basename -- "$HOSTS_FILE")"
[[ -f "$HOSTS_FILE" ]] || die "hosts file not found: $HOSTS_FILE"
jq empty "$HOSTS_FILE" >/dev/null || die "invalid JSON hosts file: $HOSTS_FILE"

[[ "${#ROLES[@]}" -gt 0 ]] || die "at least one role is required"
for role in "${ROLES[@]}"; do
    role_exists "$role" || die "role not found in $HOSTS_FILE: $role"
    [[ -n "$(role_host "$role")" ]] || die "missing ssh_host for role=$role in $HOSTS_FILE"
done

echo "SSH trust plan:"
for role in "${ROLES[@]}"; do
    printf '  role=%s target=%s@%s:%s key=~/.ssh/%s\n' \
        "$role" "$(role_user "$role")" "$(role_host "$role")" "$(role_port "$role")" "$KEY_NAME"
done

if [[ "$APPLY" != "1" ]]; then
    echo "dry-run only; pass --apply --hosts $HOSTS_FILE to generate keys and install trust"
    exit 0
fi

need_cmd ssh

declare -A PUBLIC_KEYS
for role in "${ROLES[@]}"; do
    echo "generating SSH key role=$role"
    remote_generate_key "$role"
    PUBLIC_KEYS[$role]="$(remote_read_public_key "$role")"
    [[ "${PUBLIC_KEYS[$role]}" == ssh-* ]] || die "invalid public key returned for role=$role"
done

auth_block=""
config_block=""
for role in "${ROLES[@]}"; do
    auth_block+="${PUBLIC_KEYS[$role]}"$'\n'
    config_block+="Host home-netops-$role"$'\n'
    config_block+="    HostName $(role_host "$role")"$'\n'
    config_block+="    User $(role_user "$role")"$'\n'
    config_block+="    Port $(role_port "$role")"$'\n'
    config_block+="    IdentityFile ~/.ssh/$KEY_NAME"$'\n'
    config_block+="    IdentitiesOnly yes"$'\n'
done
auth_block="${auth_block%$'\n'}"
config_block="${config_block%$'\n'}"

for role in "${ROLES[@]}"; do
    echo "installing mutual trust role=$role"
    remote_install_trust "$role" "$auth_block" "$config_block"
done

echo "SSH trust sync complete"

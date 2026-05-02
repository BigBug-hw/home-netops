#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
HOSTS_FILE="$ROOT/config/deploy-hosts.json"
CONFIG_DIR="$ROOT/config"
OUTPUT_DIR=""
APPLY=0
ROLES=(home ali tencent)
RESTART_ORDER=(tencent ali home)

usage() {
    cat <<USAGE
Usage: tools/rotate-easytier-secrets.sh [--dry-run|--apply] [options]

Options:
  --dry-run           Generate new configs locally only. This is the default.
  --apply             Upload, atomically replace, and restart remote EasyTier units.
  --hosts FILE        Deployment host map. Defaults to config/deploy-hosts.json.
  --config-dir DIR    Directory containing easytier-ROLE.yaml templates.
  --output-dir DIR    Keep generated configs in DIR instead of a temporary directory.
  --roles LIST        Space-separated roles. Defaults to: home ali tencent.
  --restart-order LIST
                      Space-separated restart order. Defaults to: tencent ali home.
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
        --config-dir)
            [[ $# -ge 2 ]] || {
                echo "ERROR: --config-dir requires a value" >&2
                exit 2
            }
            CONFIG_DIR="$2"
            shift
            ;;
        --config-dir=*)
            CONFIG_DIR="${1#*=}"
            ;;
        --output-dir)
            [[ $# -ge 2 ]] || {
                echo "ERROR: --output-dir requires a value" >&2
                exit 2
            }
            OUTPUT_DIR="$2"
            shift
            ;;
        --output-dir=*)
            OUTPUT_DIR="${1#*=}"
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
        --restart-order)
            [[ $# -ge 2 ]] || {
                echo "ERROR: --restart-order requires a value" >&2
                exit 2
            }
            read -r -a RESTART_ORDER <<< "$2"
            shift
            ;;
        --restart-order=*)
            read -r -a RESTART_ORDER <<< "${1#*=}"
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

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "ERROR: missing command: $1" >&2
        exit 1
    }
}

shell_quote() {
    local value="$1"
    printf "'%s'" "${value//\'/\'\\\'\'}"
}

json_value() {
    local role="$1" key="$2"
    jq -r --arg role "$role" --arg key "$key" '.roles[$role][$key] // empty' "$HOSTS_FILE"
}

remote_config_path() {
    local role="$1" app_home config_path
    app_home="$(json_value "$role" app_home)"
    config_path="$(json_value "$role" easytier_config)"
    [[ -n "$app_home" ]] || die "missing app_home for role=$role in $HOSTS_FILE"
    [[ -n "$config_path" ]] || die "missing easytier_config for role=$role in $HOSTS_FILE"
    case "$config_path" in
        /*) printf '%s\n' "$config_path" ;;
        *) printf '%s/%s\n' "${app_home%/}" "$config_path" ;;
    esac
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

gen_network_secret() {
    openssl rand 32 | base64 | tr '+/' '-_' | tr -d '=\n'
}

gen_x25519_keypair() {
    local pem="$1" private_out="$2" public_out="$3"

    openssl genpkey -algorithm X25519 -out "$pem" >/dev/null 2>&1
    openssl pkey -in "$pem" -outform DER | tail -c 32 | base64 | tr -d '\n' > "$private_out"
    openssl pkey -in "$pem" -pubout -outform DER | tail -c 32 | base64 | tr -d '\n' > "$public_out"
}

render_config() {
    local role="$1" source="$2" target="$3" network_secret="$4" private_key="$5" public_key="$6" tencent_public_key="$7"

    awk \
        -v role="$role" \
        -v network_secret="$network_secret" \
        -v private_key="$private_key" \
        -v public_key="$public_key" \
        -v tencent_public_key="$tencent_public_key" '
        /^[[:space:]]*network_secret[[:space:]]*=/ {
            sub(/=.*/, "= \"" network_secret "\"")
        }
        /^[[:space:]]*local_private_key[[:space:]]*=/ {
            sub(/=.*/, "= \"" private_key "\"")
        }
        /^[[:space:]]*local_public_key[[:space:]]*=/ {
            sub(/=.*/, "= \"" public_key "\"")
        }
        role != "tencent" && /^[[:space:]]*peer_public_key[[:space:]]*=/ {
            sub(/=.*/, "= \"" tencent_public_key "\"")
        }
        { print }
    ' "$source" > "$target"
}

ssh_for_role() {
    local role="$1" command="$2"
    local host user port
    host="$(json_value "$role" ssh_host)"
    user="$(json_value "$role" ssh_user)"
    port="$(json_value "$role" ssh_port)"
    [[ -n "$host" ]] || die "missing ssh_host for role=$role in $HOSTS_FILE"
    [[ -n "$user" ]] || user=root
    [[ -n "$port" ]] || port=22
    ssh -p "$port" "${user}@${host}" "$command"
}

scp_to_role() {
    local role="$1" source="$2" remote="$3"
    local host user port
    host="$(json_value "$role" ssh_host)"
    user="$(json_value "$role" ssh_user)"
    port="$(json_value "$role" ssh_port)"
    [[ -n "$host" ]] || die "missing ssh_host for role=$role in $HOSTS_FILE"
    [[ -n "$user" ]] || user=root
    [[ -n "$port" ]] || port=22
    scp -P "$port" "$source" "${user}@${host}:$remote"
}

remote_prepare() {
    local role="$1" local_config="$2" remote_config="$3" remote_tmp="$4" remote_next="$5"
    local remote_dir
    remote_dir="$(dirname -- "$remote_config")"
    scp_to_role "$role" "$local_config" "$remote_tmp"
    ssh_for_role "$role" "sudo mkdir -p $(shell_quote "$remote_dir") && sudo install -m 0600 $(shell_quote "$remote_tmp") $(shell_quote "$remote_next") && rm -f $(shell_quote "$remote_tmp") && sudo test -s $(shell_quote "$remote_next") && sudo grep -q '^network_secret = ' $(shell_quote "$remote_next") && sudo grep -q '^local_private_key = ' $(shell_quote "$remote_next") && sudo grep -q '^local_public_key = ' $(shell_quote "$remote_next")"
}

remote_commit() {
    local role="$1" remote_config="$2" remote_next="$3" backup="$4"
    ssh_for_role "$role" "if sudo test -f $(shell_quote "$remote_config"); then sudo cp -p $(shell_quote "$remote_config") $(shell_quote "$backup"); fi && sudo mv $(shell_quote "$remote_next") $(shell_quote "$remote_config")"
}

remote_restart() {
    local role="$1"
    ssh_for_role "$role" "sudo systemctl restart home-netops-easytier.service"
}

remote_rollback() {
    local role="$1" remote_config="$2" backup="$3"
    ssh_for_role "$role" "if sudo test -f $(shell_quote "$backup"); then sudo cp -p $(shell_quote "$backup") $(shell_quote "$remote_config") && sudo systemctl restart home-netops-easytier.service; fi" || true
}

remote_cleanup_backup() {
    local role="$1" backup="$2"
    ssh_for_role "$role" "sudo rm -f $(shell_quote "$backup")"
}

need_cmd jq
need_cmd openssl
need_cmd base64
need_cmd awk

CONFIG_DIR="$(cd -- "$CONFIG_DIR" && pwd)"
HOSTS_FILE="$(cd -- "$(dirname -- "$HOSTS_FILE")" && pwd)/$(basename -- "$HOSTS_FILE")"
[[ -f "$HOSTS_FILE" || "$APPLY" == "0" ]] || die "hosts file not found: $HOSTS_FILE"
if [[ -f "$HOSTS_FILE" ]]; then
    jq empty "$HOSTS_FILE" >/dev/null || die "invalid JSON hosts file: $HOSTS_FILE"
fi

if [[ "$APPLY" == "1" ]]; then
    [[ -f "$HOSTS_FILE" ]] || die "--apply requires --hosts file: $HOSTS_FILE"
    need_cmd ssh
    need_cmd scp
fi

KEEP_OUTPUT=0
if [[ -n "$OUTPUT_DIR" ]]; then
    mkdir -p "$OUTPUT_DIR"
    WORK_DIR="$(cd -- "$OUTPUT_DIR" && pwd)"
    KEEP_OUTPUT=1
else
    WORK_DIR="$(mktemp -d)"
fi
cleanup() {
    if [[ "$KEEP_OUTPUT" != "1" ]]; then
        rm -rf "$WORK_DIR"
    fi
}
trap cleanup EXIT

declare -A PRIVATE_KEYS
declare -A PUBLIC_KEYS
network_secret="$(gen_network_secret)"

for role in "${ROLES[@]}"; do
    source_config="$CONFIG_DIR/easytier-$role.yaml"
    [[ -f "$source_config" ]] || die "missing template config: $source_config"
    gen_x25519_keypair "$WORK_DIR/$role.pem" "$WORK_DIR/$role.private" "$WORK_DIR/$role.public"
    PRIVATE_KEYS[$role]="$(< "$WORK_DIR/$role.private")"
    PUBLIC_KEYS[$role]="$(< "$WORK_DIR/$role.public")"
done

[[ -n "${PUBLIC_KEYS[tencent]:-}" ]] || die "role list must include tencent so peers can pin its public key"

for role in "${ROLES[@]}"; do
    render_config \
        "$role" \
        "$CONFIG_DIR/easytier-$role.yaml" \
        "$WORK_DIR/easytier-$role.yaml" \
        "$network_secret" \
        "${PRIVATE_KEYS[$role]}" \
        "${PUBLIC_KEYS[$role]}" \
        "${PUBLIC_KEYS[tencent]}"
done

echo "generated EasyTier configs: $WORK_DIR"
for role in "${ROLES[@]}"; do
    echo "role=$role public_key=${PUBLIC_KEYS[$role]}"
done

if [[ "$APPLY" != "1" ]]; then
    echo "dry-run only; pass --apply --hosts $HOSTS_FILE to distribute and restart"
    exit 0
fi

declare -A REMOTE_CONFIGS
declare -A REMOTE_NEXTS
declare -A REMOTE_BACKUPS
timestamp="$(date +%Y%m%d%H%M%S)"

for role in "${ROLES[@]}"; do
    remote_config="$(remote_config_path "$role")"
    remote_tmp="/tmp/home-netops-easytier-$role-$timestamp.yaml"
    remote_next="$remote_config.next"
    backup="$remote_config.bak.$timestamp"
    REMOTE_CONFIGS[$role]="$remote_config"
    REMOTE_NEXTS[$role]="$remote_next"
    REMOTE_BACKUPS[$role]="$backup"
    echo "preparing role=$role remote_config=$remote_config"
    remote_prepare "$role" "$WORK_DIR/easytier-$role.yaml" "$remote_config" "$remote_tmp" "$remote_next"
done

committed=()
for role in "${ROLES[@]}"; do
    echo "installing role=$role"
    remote_commit "$role" "${REMOTE_CONFIGS[$role]}" "${REMOTE_NEXTS[$role]}" "${REMOTE_BACKUPS[$role]}"
    committed+=("$role")
done

restart_failed=0
for role in "${RESTART_ORDER[@]}"; do
    echo "restarting role=$role"
    if ! remote_restart "$role"; then
        restart_failed=1
        break
    fi
done

if [[ "$restart_failed" == "1" ]]; then
    echo "ERROR: restart failed; rolling back committed configs" >&2
    for role in "${committed[@]}"; do
        remote_rollback "$role" "${REMOTE_CONFIGS[$role]}" "${REMOTE_BACKUPS[$role]}"
    done
    exit 1
fi

for role in "${committed[@]}"; do
    echo "cleaning backup role=$role"
    remote_cleanup_backup "$role" "${REMOTE_BACKUPS[$role]}"
done

echo "EasyTier secret rotation complete"

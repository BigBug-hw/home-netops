#!/usr/bin/env bash

log() {
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    printf '[%s] %s\n' "$ts" "$*"
}

die() {
    log "ERROR: $*" >&2
    exit 1
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

json_get_services() {
    local config="$1" role="$2"

    jq -r --arg role "$role" '
        .roles[$role].services // empty
        | if type == "array" then .[] else empty end
    ' "$config"
}

json_role_exists() {
    local config="$1" role="$2"

    jq -e --arg role "$role" '.roles[$role] | type == "object"' "$config" >/dev/null
}

validate_service_name() {
    case "$1" in
        ddns|firewall|reverse-ssh|easytier|proxy-server)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

has_item() {
    local needle="$1"
    shift

    local item
    for item in "$@"; do
        [[ "$item" == "$needle" ]] && return 0
    done
    return 1
}

validate_services() {
    local service

    for service in "$@"; do
        validate_service_name "$service" || die "unknown service in config: $service"
    done

    if has_item reverse-ssh "$@" && ! has_item firewall "$@"; then
        die "reverse-ssh requires firewall in the same role"
    fi

    if has_item proxy-server "$@" && ! has_item easytier "$@"; then
        die "proxy-server requires easytier in the same role"
    fi
}

load_role_services() {
    local config="$1" role="$2"

    need_cmd jq
    [[ -f "$config" ]] || die "config not found: $config"
    jq empty "$config" >/dev/null || die "invalid JSON config: $config"
    json_role_exists "$config" "$role" || die "role not found in config: $role"
    mapfile -t HOME_NETOPS_SERVICES < <(json_get_services "$config" "$role")
    validate_services "${HOME_NETOPS_SERVICES[@]}"
}

load_config() {
    HOME_NETOPS_CONFIG="${HOME_NETOPS_CONFIG:-}"
    HOME_NETOPS_ROLE="${HOME_NETOPS_ROLE:-}"

    [[ -n "$HOME_NETOPS_CONFIG" ]] || die "HOME_NETOPS_CONFIG must be set"
    [[ -n "$HOME_NETOPS_ROLE" ]] || die "HOME_NETOPS_ROLE must be set"

    load_role_services "$HOME_NETOPS_CONFIG" "$HOME_NETOPS_ROLE"

    local key value
    while IFS=$'\t' read -r key value; do
        [[ -n "$key" ]] || continue
        [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "invalid config variable name: $key"
        if [[ -z "${!key+x}" ]]; then
            printf -v "$key" '%s' "$value"
            export "$key"
        fi
    done < <(jq -r --arg role "$HOME_NETOPS_ROLE" '
        . as $root
        | reduce ($root.roles[$role].services // [])[] as $service
            (.shared // {};
             . + ($root.services[$service] // {}) + ($root.roles[$role].overrides[$service] // {}))
        | to_entries[]
        | [.key, (.value | if type == "string" then . else tostring end)]
        | @tsv
    ' "$HOME_NETOPS_CONFIG")
}

resolve_app_path() {
    local path="$1"

    [[ -n "$path" ]] || return 0
    case "$path" in
        /*)
            printf '%s\n' "$path"
            ;;
        *)
            [[ -n "${HOME_NETOPS_APP_HOME:-}" ]] || die "HOME_NETOPS_APP_HOME must be set to resolve relative path: $path"
            printf '%s/%s\n' "${HOME_NETOPS_APP_HOME%/}" "$path"
            ;;
    esac
}

resolve_command_path() {
    local command_path="$1"

    case "$command_path" in
        /*)
            printf '%s\n' "$command_path"
            ;;
        */*)
            resolve_app_path "$command_path"
            ;;
        *)
            printf '%s\n' "$command_path"
            ;;
    esac
}

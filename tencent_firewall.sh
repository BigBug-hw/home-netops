#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/home-netops-lib.sh"

load_config

TENCENT_INSTANCE_ID="${TENCENT_INSTANCE_ID:-lhins-33uux3hm}"
TENCENT_REGION="${TENCENT_REGION:-ap-beijing}"
TENCENT_FIREWALL_PROTOCOL="${TENCENT_FIREWALL_PROTOCOL:-TCP}"
TENCENT_FIREWALL_PORT="${TENCENT_FIREWALL_PORT:-22}"
TENCENT_FIREWALL_ACTION="${TENCENT_FIREWALL_ACTION:-ACCEPT}"
TENCENT_FIREWALL_RULE_DESC="${TENCENT_FIREWALL_RULE_DESC:-auto-wsl-home-ssh}"
TCCLI_BIN="${TCCLI_BIN:-tccli}"
GET_IP_SCRIPT="${GET_IP_SCRIPT:-$SCRIPT_DIR/get_public_ip.sh}"

describe_rules() {
    "$TCCLI_BIN" lighthouse DescribeFirewallRules \
        --region "$TENCENT_REGION" \
        --InstanceId "$TENCENT_INSTANCE_ID"
}

build_rule_json() {
    local cidr="$1"

    jq -nc \
        --arg proto "$TENCENT_FIREWALL_PROTOCOL" \
        --arg port "$TENCENT_FIREWALL_PORT" \
        --arg cidr "$cidr" \
        --arg action "$TENCENT_FIREWALL_ACTION" \
        --arg desc "$TENCENT_FIREWALL_RULE_DESC" \
        '[{
          Protocol: $proto,
          Port: $port,
          CidrBlock: $cidr,
          Action: $action,
          FirewallRuleDescription: $desc
        }]'
}

create_rule() {
    local cidr="$1"
    local rule_json
    rule_json="$(build_rule_json "$cidr")"

    "$TCCLI_BIN" lighthouse CreateFirewallRules \
        --region "$TENCENT_REGION" \
        --InstanceId "$TENCENT_INSTANCE_ID" \
        --FirewallRules "$rule_json"
}

delete_rule_json() {
    local rule="$1"
    local rule_json
    rule_json="$(jq -nc --argjson rule "$rule" '[$rule]')"

    "$TCCLI_BIN" lighthouse DeleteFirewallRules \
        --region "$TENCENT_REGION" \
        --InstanceId "$TENCENT_INSTANCE_ID" \
        --FirewallRules "$rule_json"
}

main() {
    need_cmd "$TCCLI_BIN"
    need_cmd jq
    [[ -x "$GET_IP_SCRIPT" ]] || die "GET_IP_SCRIPT not executable: $GET_IP_SCRIPT"

    local current_ip cidr resp matched exact_count stale_count changed
    changed=0
    current_ip="$("$GET_IP_SCRIPT" | tr -d '\r\n[:space:]')" || die "failed to get public IPv4"
    cidr="${current_ip}/32"

    log "syncing Tencent firewall rule desc=$TENCENT_FIREWALL_RULE_DESC cidr=$cidr"

    resp="$(describe_rules)" || die "failed to describe Tencent firewall rules"
    matched="$(jq -c \
        --arg desc "$TENCENT_FIREWALL_RULE_DESC" \
        '.FirewallRuleSet[]? | select(.FirewallRuleDescription == $desc)' \
        <<< "$resp")"

    exact_count="$(jq -s \
        --arg proto "$TENCENT_FIREWALL_PROTOCOL" \
        --arg port "$TENCENT_FIREWALL_PORT" \
        --arg cidr "$cidr" \
        --arg action "$TENCENT_FIREWALL_ACTION" \
        'map(select(.Protocol == $proto and .Port == $port and .CidrBlock == $cidr and .Action == $action)) | length' \
        <<< "$matched")"

    stale_count="$(jq -s \
        --arg proto "$TENCENT_FIREWALL_PROTOCOL" \
        --arg port "$TENCENT_FIREWALL_PORT" \
        --arg cidr "$cidr" \
        --arg action "$TENCENT_FIREWALL_ACTION" \
        'map(select(.Protocol == $proto and .Port == $port and .Action == $action and .CidrBlock != $cidr)) | length' \
        <<< "$matched")"

    if (( stale_count > 0 )); then
        while IFS= read -r rule; do
            [[ -n "$rule" ]] || continue
            log "deleting stale Tencent firewall rule: $(jq -c . <<< "$rule")"
            delete_rule_json "$rule"
            changed=1
        done < <(jq -c \
            --arg proto "$TENCENT_FIREWALL_PROTOCOL" \
            --arg port "$TENCENT_FIREWALL_PORT" \
            --arg cidr "$cidr" \
            --arg action "$TENCENT_FIREWALL_ACTION" \
            'select(.Protocol == $proto and .Port == $port and .Action == $action and .CidrBlock != $cidr)' \
            <<< "$matched")
    fi

    if (( exact_count > 0 )); then
        log "firewall_changed=$changed"
        log "no change: Tencent firewall already allows $cidr"
        exit 0
    fi

    log "creating Tencent firewall rule for $cidr"
    create_rule "$cidr"
    changed=1
    log "firewall_changed=$changed"
    log "Tencent firewall update success"
}

main "$@"

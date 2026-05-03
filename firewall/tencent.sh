#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/common.sh"

load_config

TENCENT_INSTANCE_ID="${TENCENT_INSTANCE_ID:-lhins-33uux3hm}"
TENCENT_REGION="${TENCENT_REGION:-ap-beijing}"
TCCLI_BIN="${TCCLI_BIN:-${HOME_NETOPS_APP_HOME:-$ROOT_DIR}/.venv/bin/tccli}"
TCCLI_BIN="$(resolve_command_path "$TCCLI_BIN")"
GET_IP_SCRIPT="${GET_IP_SCRIPT:-$ROOT_DIR/lib/get-public-ip.sh}"
GET_IP_SCRIPT="$(resolve_app_path "$GET_IP_SCRIPT")"
SYSTEMCTL_BIN="${SYSTEMCTL_BIN:-systemctl}"
RESTART_REVERSE_AFTER_FIREWALL_CHANGE="${RESTART_REVERSE_AFTER_FIREWALL_CHANGE:-1}"
TENCENT_FIREWALL_RULES="${TENCENT_FIREWALL_RULES:-}"
TENCENT_FIREWALL_RULE_DESC_PREFIX="${TENCENT_FIREWALL_RULE_DESC_PREFIX:-home-netops: }"

ensure_tccli() {
    if [[ -x "$TCCLI_BIN" ]]; then
        return 0
    fi

    case "$TCCLI_BIN" in
        */*)
            need_cmd uv
            [[ -n "${HOME_NETOPS_APP_HOME:-}" ]] || die "HOME_NETOPS_APP_HOME must be set to install tccli into app venv"
            log "TCCLI_BIN not found, installing tccli into ${HOME_NETOPS_APP_HOME}/.venv"
            (cd "$HOME_NETOPS_APP_HOME" && uv venv && uv pip install tccli)
            ;;
    esac
}

describe_rules() {
    "$TCCLI_BIN" lighthouse DescribeFirewallRules \
        --region "$TENCENT_REGION" \
        --InstanceId "$TENCENT_INSTANCE_ID"
}

build_rule_json() {
    local rule="$1"

    jq -nc --argjson rule "$rule" '[$rule]'
}

create_rule() {
    local rule="$1"
    local rule_json
    rule_json="$(build_rule_json "$rule")"

    "$TCCLI_BIN" lighthouse CreateFirewallRules \
        --region "$TENCENT_REGION" \
        --InstanceId "$TENCENT_INSTANCE_ID" \
        --FirewallRules "$rule_json"
}

delete_rule_json() {
    local rule="$1"
    local rule_json
    rule_json="$(jq -nc --argjson rule "$rule" '
        [$rule
         | {
             Protocol,
             Port,
             CidrBlock,
             Action,
             FirewallRuleDescription
           }
         | if (($rule.Ipv6CidrBlock // "") != "") then
             . + {Ipv6CidrBlock: $rule.Ipv6CidrBlock}
           else
             .
           end]
    ')"

    "$TCCLI_BIN" lighthouse DeleteFirewallRules \
        --region "$TENCENT_REGION" \
        --InstanceId "$TENCENT_INSTANCE_ID" \
        --FirewallRules "$rule_json"
}

restart_reverse_ssh_if_needed() {
    local changed="$1"

    if [[ "$RESTART_REVERSE_AFTER_FIREWALL_CHANGE" == "1" ]] \
        && [[ "$changed" == "1" ]] \
        && "$SYSTEMCTL_BIN" list-unit-files home-netops-reverse-ssh.service >/dev/null 2>&1; then
        "$SYSTEMCTL_BIN" try-restart home-netops-reverse-ssh.service
    fi
}

target_rules_json() {
    local cidr="$1"

    [[ -n "$TENCENT_FIREWALL_RULES" ]] || die "TENCENT_FIREWALL_RULES must be set"

    [[ -n "$TENCENT_FIREWALL_RULE_DESC_PREFIX" ]] || die "TENCENT_FIREWALL_RULE_DESC_PREFIX must not be empty"

    jq -ec --arg cidr "$cidr" --arg desc_prefix "$TENCENT_FIREWALL_RULE_DESC_PREFIX" '
        def non_empty_string($key):
            has($key) and (.[$key] | type == "string" and length > 0);
        def valid_rule:
            type == "object"
            and non_empty_string("Protocol")
            and has("Port")
            and ((.Port | type) == "string" or (.Port | type) == "number")
            and ((.Port | tostring) | length > 0)
            and non_empty_string("Action")
            and non_empty_string("FirewallRuleDescription")
            and ((has("CidrBlock") | not) or (.CidrBlock | type == "string" and length > 0));

        if type != "array" or length == 0 then
            error("TENCENT_FIREWALL_RULES must be a non-empty JSON array")
        else
            map(
                if valid_rule and (.FirewallRuleDescription | startswith($desc_prefix) | not) then
                    {
                        Protocol,
                        Port: (.Port | tostring),
                        CidrBlock: (.CidrBlock // $cidr),
                        Action,
                        FirewallRuleDescription: ($desc_prefix + .FirewallRuleDescription)
                    }
                else
                    error("each Tencent firewall rule must include Protocol, Port, Action, a non-prefixed FirewallRuleDescription, and optional non-empty CidrBlock")
                end
            ) as $rules
            | if ($rules | length) != ($rules | unique_by([.Protocol, .Port, .CidrBlock, .Action, .FirewallRuleDescription]) | length) then
                error("TENCENT_FIREWALL_RULES contains duplicate target rules")
              else
                $rules
              end
        end
    ' <<< "$TENCENT_FIREWALL_RULES" || die "invalid TENCENT_FIREWALL_RULES"
}

main() {
    need_cmd jq
    ensure_tccli
    need_cmd "$TCCLI_BIN"
    [[ -x "$GET_IP_SCRIPT" ]] || die "GET_IP_SCRIPT not executable: $GET_IP_SCRIPT"

    local current_ip cidr resp target_rules stale_count missing_count changed
    changed=0
    current_ip="$("$GET_IP_SCRIPT" | tr -d '\r\n[:space:]')" || die "failed to get public IPv4"
    cidr="${current_ip}"
    target_rules="$(target_rules_json "$cidr")"

    log "syncing Tencent firewall rules count=$(jq 'length' <<< "$target_rules") cidr=$cidr"

    resp="$(describe_rules)" || die "failed to describe Tencent firewall rules"

    stale_count="$(jq \
        --argjson target "$target_rules" \
        --arg desc_prefix "$TENCENT_FIREWALL_RULE_DESC_PREFIX" \
        '[
            .FirewallRuleSet[]?
            | select((.FirewallRuleDescription // "") | startswith($desc_prefix))
            | select(. as $existing |
                any($target[];
                    .Protocol == $existing.Protocol
                    and .Port == $existing.Port
                    and .CidrBlock == $existing.CidrBlock
                    and .Action == $existing.Action
                    and .FirewallRuleDescription == $existing.FirewallRuleDescription
                ) | not
            )
        ] | length' \
        <<< "$resp")"

    if (( stale_count > 0 )); then
        while IFS= read -r rule; do
            [[ -n "$rule" ]] || continue
            log "deleting stale Tencent firewall rule: $(jq -c . <<< "$rule")"
            delete_rule_json "$rule"
            changed=1
        done < <(jq -c \
            --argjson target "$target_rules" \
            --arg desc_prefix "$TENCENT_FIREWALL_RULE_DESC_PREFIX" \
            '.FirewallRuleSet[]?
             | select((.FirewallRuleDescription // "") | startswith($desc_prefix))
             | select(. as $existing |
                 any($target[];
                     .Protocol == $existing.Protocol
                     and .Port == $existing.Port
                     and .CidrBlock == $existing.CidrBlock
                     and .Action == $existing.Action
                     and .FirewallRuleDescription == $existing.FirewallRuleDescription
                 ) | not
             )' \
            <<< "$resp")
    fi

    missing_count="$(jq -n \
        --argjson target "$target_rules" \
        --argjson resp "$resp" \
        '[
            $target[]
            | select(. as $wanted |
                any($resp.FirewallRuleSet[]?;
                    .Protocol == $wanted.Protocol
                    and .Port == $wanted.Port
                    and .CidrBlock == $wanted.CidrBlock
                    and .Action == $wanted.Action
                    and .FirewallRuleDescription == $wanted.FirewallRuleDescription
                ) | not
            )
        ] | length')"

    if (( missing_count > 0 )); then
        while IFS= read -r rule; do
            [[ -n "$rule" ]] || continue
            log "creating Tencent firewall rule: $(jq -c . <<< "$rule")"
            create_rule "$rule"
            changed=1
        done < <(jq -nc \
            --argjson target "$target_rules" \
            --argjson resp "$resp" \
            '$target[]
             | select(. as $wanted |
                 any($resp.FirewallRuleSet[]?;
                     .Protocol == $wanted.Protocol
                     and .Port == $wanted.Port
                     and .CidrBlock == $wanted.CidrBlock
                     and .Action == $wanted.Action
                     and .FirewallRuleDescription == $wanted.FirewallRuleDescription
                 ) | not
             )')
    fi

    log "firewall_changed=$changed"
    if [[ "$changed" == "0" ]]; then
        log "no change: Tencent firewall already matches target rules"
    fi
    restart_reverse_ssh_if_needed "$changed"
    log "Tencent firewall update success"
}

main "$@"

#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/common.sh"

load_config

ALIYUN_BIN="${ALIYUN_BIN:-aliyun}"
ALIYUN_FIREWALL_PROFILE="${ALIYUN_FIREWALL_PROFILE:-${ALIYUN_PROFILE:-default}}"
ALIYUN_INSTANCE_ID="${ALIYUN_INSTANCE_ID:-}"
ALIYUN_BIZ_REGION_ID="${ALIYUN_BIZ_REGION_ID:-}"
ALIYUN_FIREWALL_RULES="${ALIYUN_FIREWALL_RULES:-}"
ALIYUN_FIREWALL_RULE_REMARK_PREFIX="${ALIYUN_FIREWALL_RULE_REMARK_PREFIX:-home-netops: }"
GET_IP_SCRIPT="${GET_IP_SCRIPT:-$ROOT_DIR/lib/get-public-ip.sh}"
GET_IP_SCRIPT="$(resolve_app_path "$GET_IP_SCRIPT")"
SYSTEMCTL_BIN="${SYSTEMCTL_BIN:-systemctl}"
RESTART_REVERSE_AFTER_FIREWALL_CHANGE="${RESTART_REVERSE_AFTER_FIREWALL_CHANGE:-1}"

aliyun_cli() {
    "$ALIYUN_BIN" --profile "$ALIYUN_FIREWALL_PROFILE" "$@"
}

describe_rules() {
    aliyun_cli swas-open list-firewall-rules \
        --instance-id "$ALIYUN_INSTANCE_ID" \
        --biz-region-id "$ALIYUN_BIZ_REGION_ID"
}

create_rule() {
    local rule="$1"
    local remark
    remark="$(jq -r '.Remark' <<< "$rule")"

    local args=(
        swas-open create-firewall-rule
        --instance-id "$ALIYUN_INSTANCE_ID"
        --biz-region-id "$ALIYUN_BIZ_REGION_ID"
        --rule-protocol "$(jq -r '.RuleProtocol' <<< "$rule")"
        --port "$(jq -r '.Port' <<< "$rule")"
    )
    if [[ -n "$remark" && "$remark" != "null" ]]; then
        args+=(--remark "$remark")
    fi

    aliyun_cli "${args[@]}"
}

modify_rule() {
    local rule_id="$1" rule="$2"
    local remark
    remark="$(jq -r '.Remark' <<< "$rule")"

    local args=(
        swas-open modify-firewall-rule
        --instance-id "$ALIYUN_INSTANCE_ID"
        --biz-region-id "$ALIYUN_BIZ_REGION_ID"
        --rule-id "$rule_id"
        --rule-protocol "$(jq -r '.RuleProtocol' <<< "$rule")"
        --port "$(jq -r '.Port' <<< "$rule")"
        --source-cidr-ip "$(jq -r '.SourceCidrIp' <<< "$rule")"
    )
    if [[ -n "$remark" && "$remark" != "null" ]]; then
        args+=(--remark "$remark")
    fi

    aliyun_cli "${args[@]}"
}

set_rule_policy() {
    local rule_id="$1" policy="$2"
    local action

    case "$policy" in
        accept)
            action=enable-firewall-rule
            ;;
        drop)
            action=disable-firewall-rule
            ;;
        *)
            die "unsupported Aliyun firewall policy: $policy"
            ;;
    esac

    aliyun_cli swas-open "$action" \
        --instance-id "$ALIYUN_INSTANCE_ID" \
        --biz-region-id "$ALIYUN_BIZ_REGION_ID" \
        --rule-id "$rule_id"
}

delete_rule_id() {
    local rule_id="$1"

    aliyun_cli swas-open delete-firewall-rule \
        --instance-id "$ALIYUN_INSTANCE_ID" \
        --biz-region-id "$ALIYUN_BIZ_REGION_ID" \
        --rule-id "$rule_id"
}

target_rules_json() {
    local cidr="$1"

    [[ -n "$ALIYUN_FIREWALL_RULES" ]] || die "ALIYUN_FIREWALL_RULES must be set"
    [[ -n "$ALIYUN_FIREWALL_RULE_REMARK_PREFIX" ]] || die "ALIYUN_FIREWALL_RULE_REMARK_PREFIX must not be empty"

    jq -ec --arg cidr "$cidr" --arg remark_prefix "$ALIYUN_FIREWALL_RULE_REMARK_PREFIX" '
        def non_empty_string($key):
            has($key) and (.[$key] | type == "string" and length > 0);
        def valid_rule:
            type == "object"
            and non_empty_string("RuleProtocol")
            and has("Port")
            and ((.Port | type) == "string" or (.Port | type) == "number")
            and ((.Port | tostring) | length > 0)
            and ((has("Policy") | not) or (.Policy == "accept" or .Policy == "drop"))
            and ((has("SourceCidrIp") | not) or (.SourceCidrIp | type == "string" and length > 0))
            and ((has("Remark") | not) or (.Remark | type == "string" and length > 0 and (startswith($remark_prefix) | not)));

        if type != "array" or length == 0 then
            error("ALIYUN_FIREWALL_RULES must be a non-empty JSON array")
        else
            map(
                if valid_rule then
                    {
                        RuleProtocol,
                        Port: (.Port | tostring),
                        SourceCidrIp: (.SourceCidrIp // $cidr),
                        Policy: (.Policy // "accept"),
                        Remark: (if has("Remark") then $remark_prefix + .Remark else "" end)
                    }
                else
                    error("each Aliyun firewall rule must include RuleProtocol, Port, optional Policy accept/drop, optional SourceCidrIp, and optional non-prefixed Remark")
                end
            ) as $rules
            | if ($rules | length) != ($rules | unique_by([.RuleProtocol, .Port, .SourceCidrIp, .Policy]) | length) then
                error("ALIYUN_FIREWALL_RULES contains duplicate target rules")
              else
                $rules
              end
        end
    ' <<< "$ALIYUN_FIREWALL_RULES" || die "invalid ALIYUN_FIREWALL_RULES"
}

find_existing_rule_id() {
    local resp="$1" rule="$2"

    jq -r --argjson wanted "$rule" '
        [
            .FirewallRules[]?
            | select(.RuleProtocol == $wanted.RuleProtocol and .Port == $wanted.Port)
        ] as $same_port
        | [
            $same_port[]
            | select(.SourceCidrIp == $wanted.SourceCidrIp and .Policy == $wanted.Policy)
        ] as $exact
        | [
            $same_port[]
            | select((.Remark // "") == $wanted.Remark and ($wanted.Remark // "") != "")
        ] as $same_remark
        | if ($exact | length) > 0 then
            $exact[0].RuleId
          elif ($same_remark | length) == 1 then
            $same_remark[0].RuleId
          else
            ""
          end
    ' <<< "$resp"
}

find_created_rule_id() {
    local before="$1" after="$2" rule="$3"

    jq -r --argjson before "$before" --argjson wanted "$rule" '
        [
            .FirewallRules[]?
            | select(.RuleProtocol == $wanted.RuleProtocol and .Port == $wanted.Port)
            | select(.RuleId as $id | any($before.FirewallRules[]?; .RuleId == $id) | not)
        ]
        | if length == 1 then .[0].RuleId else "" end
    ' <<< "$after"
}

restart_reverse_ssh_if_needed() {
    local changed="$1"

    if [[ "$RESTART_REVERSE_AFTER_FIREWALL_CHANGE" == "1" ]] \
        && [[ "$changed" == "1" ]] \
        && "$SYSTEMCTL_BIN" list-unit-files home-netops-reverse-ssh.service >/dev/null 2>&1; then
        "$SYSTEMCTL_BIN" try-restart home-netops-reverse-ssh.service
    fi
}

main() {
    need_cmd jq
    need_cmd "$ALIYUN_BIN"
    [[ -x "$GET_IP_SCRIPT" ]] || die "GET_IP_SCRIPT not executable: $GET_IP_SCRIPT"
    [[ -n "$ALIYUN_INSTANCE_ID" ]] || die "ALIYUN_INSTANCE_ID must be set"
    [[ -n "$ALIYUN_BIZ_REGION_ID" ]] || die "ALIYUN_BIZ_REGION_ID must be set"

    local current_ip target_rules resp changed stale_count rule rule_id after before_resp create_resp
    changed=0
    current_ip="$("$GET_IP_SCRIPT" | tr -d '\r\n[:space:]')" || die "failed to get public IPv4"
    target_rules="$(target_rules_json "$current_ip")"

    log "syncing Aliyun firewall rules count=$(jq 'length' <<< "$target_rules") cidr=$current_ip"

    resp="$(describe_rules)" || die "failed to describe Aliyun firewall rules"

    stale_count="$(jq \
        --argjson target "$target_rules" \
        --arg remark_prefix "$ALIYUN_FIREWALL_RULE_REMARK_PREFIX" \
        '[
            .FirewallRules[]?
            | select((.Remark // "") | startswith($remark_prefix))
            | select(. as $existing |
                any($target[];
                    .RuleProtocol == $existing.RuleProtocol
                    and .Port == $existing.Port
                    and .SourceCidrIp == $existing.SourceCidrIp
                    and .Policy == $existing.Policy
                ) | not
            )
        ] | length' \
        <<< "$resp")"

    if (( stale_count > 0 )); then
        while IFS= read -r rule_id; do
            [[ -n "$rule_id" ]] || continue
            log "deleting stale Aliyun firewall rule: RuleId=$rule_id"
            delete_rule_id "$rule_id"
            changed=1
        done < <(jq -r \
            --argjson target "$target_rules" \
            --arg remark_prefix "$ALIYUN_FIREWALL_RULE_REMARK_PREFIX" \
            '.FirewallRules[]?
             | select((.Remark // "") | startswith($remark_prefix))
             | select(. as $existing |
                 any($target[];
                     .RuleProtocol == $existing.RuleProtocol
                     and .Port == $existing.Port
                     and .SourceCidrIp == $existing.SourceCidrIp
                     and .Policy == $existing.Policy
                 ) | not
             )
             | .RuleId' \
            <<< "$resp")
        resp="$(describe_rules)" || die "failed to describe Aliyun firewall rules after deleting stale rules"
    fi

    while IFS= read -r rule; do
        [[ -n "$rule" ]] || continue
        rule_id="$(find_existing_rule_id "$resp" "$rule")"

        if [[ -n "$rule_id" && "$rule_id" != "null" ]]; then
            log "updating Aliyun firewall rule: RuleId=$rule_id target=$(jq -c . <<< "$rule")"
            modify_rule "$rule_id" "$rule"
            set_rule_policy "$rule_id" "$(jq -r '.Policy' <<< "$rule")"
            changed=1
            resp="$(describe_rules)" || die "failed to describe Aliyun firewall rules after updating rule"
            continue
        fi

        log "creating Aliyun firewall rule: $(jq -c . <<< "$rule")"
        before_resp="$resp"
        create_resp="$(create_rule "$rule")"
        after="$(describe_rules)" || die "failed to describe Aliyun firewall rules after creating rule"
        rule_id="$(jq -r '.RuleId // empty' <<< "$create_resp")"
        if [[ -z "$rule_id" || "$rule_id" == "null" ]]; then
            rule_id="$(find_created_rule_id "$before_resp" "$after" "$rule")"
        fi
        [[ -n "$rule_id" && "$rule_id" != "null" ]] || die "failed to identify created Aliyun firewall rule for target: $(jq -c . <<< "$rule")"
        modify_rule "$rule_id" "$rule"
        set_rule_policy "$rule_id" "$(jq -r '.Policy' <<< "$rule")"
        changed=1
        resp="$(describe_rules)" || die "failed to describe Aliyun firewall rules after creating target rule"
    done < <(jq -nc \
        --argjson target "$target_rules" \
        --argjson resp "$resp" \
        '$target[]
         | select(. as $wanted |
             any($resp.FirewallRules[]?;
                 .RuleProtocol == $wanted.RuleProtocol
                 and .Port == $wanted.Port
                 and .SourceCidrIp == $wanted.SourceCidrIp
                 and .Policy == $wanted.Policy
             ) | not
         )')

    log "firewall_changed=$changed"
    if [[ "$changed" == "0" ]]; then
        log "no change: Aliyun firewall already matches target rules"
    fi
    restart_reverse_ssh_if_needed "$changed"
    log "Aliyun firewall update success"
}

main "$@"

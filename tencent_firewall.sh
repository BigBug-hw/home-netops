#!/usr/bin/env bash
set -euo pipefail

########################################
# 配置区：按你的实际情况修改
########################################
INSTANCE_ID="lhins-33uux3hm"
REGION="ap-beijing"

GET_IP_SCRIPT="./get_public_ip.sh"

# 要放行的端口：你的场景是登录云主机 SSH
PROTOCOL="TCP"
PORT="22"
ACTION="ACCEPT"

# 用 description 标识本脚本维护的规则
# 注意腾讯云限制 FirewallRuleDescription 最长 64 字符
RULE_DESC="auto-wsl-home-ssh"

# tccli 路径
TCCLI_BIN="./.venv/bin/tccli"

########################################

log() {
    echo "[$(date '+%F %T')] $*"
}

die() {
    echo "[$(date '+%F %T')] ERROR: $*" >&2
    exit 1
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "command not found: $1"
}

need_cmd "$TCCLI_BIN"
need_cmd jq

[[ -x "$GET_IP_SCRIPT" ]] || die "GET_IP_SCRIPT not executable: $GET_IP_SCRIPT"

CURRENT_IP="$("$GET_IP_SCRIPT" | tr -d '\r\n[:space:]')"

[[ "$CURRENT_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "invalid public IP: $CURRENT_IP"

CIDR="${CURRENT_IP}/32"

log "current public IP: $CURRENT_IP"
log "target rule: ${PROTOCOL} ${PORT} ${CIDR} ${ACTION} desc=${RULE_DESC}"

describe_rules() {
    "$TCCLI_BIN" lighthouse DescribeFirewallRules \
        --region "$REGION" \
        --InstanceId "$INSTANCE_ID" \
        --Limit 100 \
        --output json
}

firewall_rules() {
    jq -nc \
      --arg proto "$PROTOCOL" \
      --arg port "$PORT" \
      --arg cidr "$cidr" \
      --arg desc "$RULE_DESC" \
      '[
        {
          Protocol: $proto,
          Port: $port,
          CidrBlock: $cidr,
          Action: "ACCEPT",
          FirewallRuleDescription: $desc
        }
      ]'
}

create_rule() {
    local cidr="$1"
    local rule_json="$(firewall_rules)"

    log "creating firewall rule: ${PROTOCOL} ${PORT} ${cidr}"

    "$TCCLI_BIN" lighthouse CreateFirewallRules \
        --region "$REGION" \
        --InstanceId "$INSTANCE_ID" \
        --FirewallRules "$rule_json" \
        >/dev/null
}

delete_rule() {
    local proto="$1"
    local port="$2"
    local cidr="$3"
    local action="$4"
    local desc="$5"
    local rule_json="$(firewall_rules)"

    log "deleting stale rule: ${proto} ${port} ${cidr} ${action} desc=${desc}"

    "$TCCLI_BIN" lighthouse DeleteFirewallRules \
        --region "$REGION" \
        --InstanceId "$INSTANCE_ID" \
        --FirewallRules "$rule_json" \
        >/dev/null
}

RESP="$(describe_rules)"

# 找出本脚本维护的规则：通过 description 精确匹配
MATCHED_RULES="$(
    echo "$RESP" | jq -c \
      --arg desc "$RULE_DESC" \
      '.FirewallRuleSet[]? | select(.FirewallRuleDescription == $desc)'
)"

MATCH_COUNT="$(echo "$MATCHED_RULES" | sed '/^$/d' | wc -l | awk '{print $1}')"

if [[ "$MATCH_COUNT" -eq 0 ]]; then
    log "managed rule not found"
    create_rule "$CIDR"
    log "done"
    exit 0
fi

# 如果存在多条相同 description 的规则，只保留/重建为一条，避免历史垃圾规则堆积
NEED_CREATE=0
FOUND_EXACT=0

while IFS= read -r rule; do
    [[ -n "$rule" ]] || continue

    proto="$(echo "$rule" | jq -r '.Protocol')"
    port="$(echo "$rule" | jq -r '.Port')"
    cidr="$(echo "$rule" | jq -r '.CidrBlock')"
    action="$(echo "$rule" | jq -r '.Action')"
    desc="$(echo "$rule" | jq -r '.FirewallRuleDescription')"

    if [[ "$proto" == "$PROTOCOL" && "$port" == "$PORT" && "$cidr" == "$CIDR" && "$action" == "$ACTION" ]]; then
        if [[ "$FOUND_EXACT" -eq 0 ]]; then
            FOUND_EXACT=1
            log "firewall rule already up to date"
        else
            # 多余重复规则，删除
            delete_rule "$proto" "$port" "$cidr" "$action" "$desc"
        fi
    else
        # IP 或端口/协议不一致，删除旧规则
        delete_rule "$proto" "$port" "$cidr" "$action" "$desc"
        NEED_CREATE=1
    fi
done <<< "$MATCHED_RULES"

if [[ "$FOUND_EXACT" -eq 0 ]]; then
    NEED_CREATE=1
fi

if [[ "$NEED_CREATE" -eq 1 ]]; then
    create_rule "$CIDR"
fi

log "done"

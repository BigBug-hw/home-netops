#!/usr/bin/env bash
set -euo pipefail

# ========== 用户配置 ==========
PROFILE="ddns"

# 主域名，例如 example.com
DOMAIN_NAME="bigbug.ren"

# 主机记录：
# home.example.com 填 home
# example.com 根域名填 @
RR="home"

# A = IPv4
# AAAA = IPv6，若用 IPv6，需要替换 get_public_ip 里的 IP 获取地址
TYPE="A"

# 解析线路，一般保持 default
LINE="default"

# TTL，阿里云默认 600 秒；如果你的套餐支持更低 TTL，可以改小
TTL="600"

# 日志文件
LOG_FILE="/home/renyq/software/aiagent/aliyun-ddns.log"

GET_IP_SCRIPT="./get_public_ip.sh"
# ========== 内部逻辑 ==========

log() {
    local msg="$*"
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[$ts] $msg" | tee -a "$LOG_FILE"
}

die() {
    log "ERROR: $*"
    exit 1
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

build_subdomain() {
    if [[ "$RR" == "@" ]]; then
        echo "$DOMAIN_NAME"
    else
        echo "${RR}.${DOMAIN_NAME}"
    fi
}

query_record() {
    local subdomain="$1"

    aliyun --profile "$PROFILE" alidns DescribeSubDomainRecords \
        --SubDomain "$subdomain" \
        --Type "$TYPE"
}

main() {
    need_cmd curl
    need_cmd jq
    need_cmd aliyun

    [[ -x "$GET_IP_SCRIPT" ]] || die "GET_IP_SCRIPT not executable: $GET_IP_SCRIPT"

    local subdomain
    subdomain="$(build_subdomain)"

    local public_ip
    public_ip="$("$GET_IP_SCRIPT" | tr -d '\r\n[:space:]')" || die "failed to get public IPv4"

    log "public_ip=$public_ip, subdomain=$subdomain, type=$TYPE"

    local resp
    resp="$(query_record "$subdomain")" || die "failed to query DNS record"

    local total
    total="$(echo "$resp" | jq -r '.TotalCount // 0')"

    if [[ "$total" == "0" ]]; then
        die "record not found: ${subdomain} ${TYPE}. Please create it once in Aliyun DNS console first."
    fi

    # 精确匹配 RR + Type + Line
    # 注意：DescribeSubDomainRecords 已经按完整子域名查过，这里再过滤一次，避免多线路/多记录误更新
    local matched
    matched="$(echo "$resp" | jq -c \
        --arg rr "$RR" \
        --arg type "$TYPE" \
        --arg line "$LINE" \
        '
        .DomainRecords.Record
        | map(select(.RR == $rr and .Type == $type and ((.Line // "default") == $line)))
        ')"

    local matched_count
    matched_count="$(echo "$matched" | jq 'length')"

    if [[ "$matched_count" == "0" ]]; then
        die "no matched record for RR=$RR TYPE=$TYPE LINE=$LINE"
    fi

    if [[ "$matched_count" != "1" ]]; then
        echo "$matched" | jq .
        die "multiple matched records found, refuse to update automatically"
    fi

    local record_id current_value
    record_id="$(echo "$matched" | jq -r '.[0].RecordId')"
    current_value="$(echo "$matched" | jq -r '.[0].Value')"

    if [[ -z "$record_id" || "$record_id" == "null" ]]; then
        die "RecordId is empty"
    fi

    if [[ "$current_value" == "$public_ip" ]]; then
        log "no change: ${subdomain} already points to ${public_ip}"
        exit 0
    fi

    log "updating: ${subdomain} ${TYPE} ${current_value} -> ${public_ip}, RecordId=${record_id}"

    aliyun --profile "$PROFILE" alidns UpdateDomainRecord \
        --RecordId "$record_id" \
        --RR "$RR" \
        --Type "$TYPE" \
        --Value "$public_ip" \
        --TTL "$TTL" \
        --Line "$LINE" \
        --output json >/tmp/aliyun-ddns-update.$$ 2>/tmp/aliyun-ddns-error.$$

    if [[ $? -eq 0 ]]; then
        log "update success: ${subdomain} -> ${public_ip}"
        rm -f /tmp/aliyun-ddns-update.$$ /tmp/aliyun-ddns-error.$$
    else
        cat /tmp/aliyun-ddns-error.$$ >&2 || true
        die "update failed"
    fi
}

main "$@"

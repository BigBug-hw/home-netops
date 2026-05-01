#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/common.sh"

load_config

ALIYUN_PROFILE="${ALIYUN_PROFILE:-ddns}"
ALIYUN_DOMAIN_NAME="${ALIYUN_DOMAIN_NAME:-bigbug.ren}"
ALIYUN_RR="${ALIYUN_RR:-home}"
ALIYUN_TYPE="${ALIYUN_TYPE:-A}"
ALIYUN_LINE="${ALIYUN_LINE:-default}"
ALIYUN_TTL="${ALIYUN_TTL:-600}"
GET_IP_SCRIPT="${GET_IP_SCRIPT:-$ROOT_DIR/lib/get-public-ip.sh}"
ALIYUN_BIN="${ALIYUN_BIN:-aliyun}"

build_subdomain() {
    if [[ "$ALIYUN_RR" == "@" ]]; then
        printf '%s\n' "$ALIYUN_DOMAIN_NAME"
    else
        printf '%s.%s\n' "$ALIYUN_RR" "$ALIYUN_DOMAIN_NAME"
    fi
}

query_record() {
    local subdomain="$1"

    "$ALIYUN_BIN" --profile "$ALIYUN_PROFILE" alidns DescribeSubDomainRecords \
        --SubDomain "$subdomain" \
        --Type "$ALIYUN_TYPE"
}

main() {
    need_cmd curl
    need_cmd jq
    need_cmd "$ALIYUN_BIN"

    [[ -x "$GET_IP_SCRIPT" ]] || die "GET_IP_SCRIPT not executable: $GET_IP_SCRIPT"

    local subdomain public_ip resp total matched matched_count record_id current_value output
    subdomain="$(build_subdomain)"
    public_ip="$("$GET_IP_SCRIPT" | tr -d '\r\n[:space:]')" || die "failed to get public IPv4"

    log "public_ip=$public_ip subdomain=$subdomain type=$ALIYUN_TYPE"

    resp="$(query_record "$subdomain")" || die "failed to query DNS record"
    total="$(jq -r '.TotalCount // 0' <<< "$resp")"

    if [[ "$total" == "0" ]]; then
        die "record not found: ${subdomain} ${ALIYUN_TYPE}. Create it once in Aliyun DNS console first."
    fi

    matched="$(jq -c \
        --arg rr "$ALIYUN_RR" \
        --arg type "$ALIYUN_TYPE" \
        --arg line "$ALIYUN_LINE" \
        '.DomainRecords.Record | map(select(.RR == $rr and .Type == $type and ((.Line // "default") == $line)))' \
        <<< "$resp")"
    matched_count="$(jq 'length' <<< "$matched")"

    if [[ "$matched_count" == "0" ]]; then
        die "no matched record for RR=$ALIYUN_RR TYPE=$ALIYUN_TYPE LINE=$ALIYUN_LINE"
    fi

    if [[ "$matched_count" != "1" ]]; then
        jq . <<< "$matched"
        die "multiple matched records found, refuse to update automatically"
    fi

    record_id="$(jq -r '.[0].RecordId' <<< "$matched")"
    current_value="$(jq -r '.[0].Value' <<< "$matched")"

    [[ -n "$record_id" && "$record_id" != "null" ]] || die "RecordId is empty"

    if [[ "$current_value" == "$public_ip" ]]; then
        log "no change: ${subdomain} already points to ${public_ip}"
        exit 0
    fi

    log "updating: ${subdomain} ${ALIYUN_TYPE} ${current_value} -> ${public_ip}, RecordId=${record_id}"

    if output="$("$ALIYUN_BIN" --profile "$ALIYUN_PROFILE" alidns UpdateDomainRecord \
        --RecordId "$record_id" \
        --RR "$ALIYUN_RR" \
        --Type "$ALIYUN_TYPE" \
        --Value "$public_ip" \
        --TTL "$ALIYUN_TTL" \
        --Line "$ALIYUN_LINE" \
        2>&1)"; then
        log "update success: ${subdomain} -> ${public_ip}"
    else
        printf '%s\n' "$output" >&2
        die "update failed"
    fi
}

main "$@"

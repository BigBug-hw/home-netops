#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_file() {
    [[ -e "$1" ]] || fail "missing file: $1"
}

assert_not_file() {
    [[ ! -e "$1" ]] || fail "unexpected file: $1"
}

assert_grep() {
    grep -q -- "$1" "$2" || fail "$3"
}

assert_not_grep() {
    if grep -q -- "$1" "$2"; then
        fail "$3"
    fi
}

scripts=(
    check.sh
    ddns/aliyun.sh
    firewall/aliyun.sh
    firewall/tencent.sh
    install.sh
    lib/common.sh
    lib/easytier.sh
    lib/get-public-ip.sh
    lib/proxy-client.sh
    lib/proxy-server.sh
    lib/reverse-ssh.sh
    tools/rotate-easytier-secrets.sh
    uninstall.sh
)

for script in "${scripts[@]}"; do
    bash -n "$ROOT/$script"
done

jq empty "$ROOT/config/home-netops.json"

mockbin="$TMP/bin"
mkdir -p "$mockbin"
cat > "$mockbin/systemctl" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "systemctl $*" >> "$SYSTEMCTL_LOG"
case "$1" in
    is-enabled|is-active)
        if [[ "$1" == "is-active" && -n "${SYSTEMCTL_INACTIVE_UNIT:-}" && "$2" == "$SYSTEMCTL_INACTIVE_UNIT" ]]; then
            printf 'inactive\n'
            exit 3
        fi
        [[ -e "$SYSTEMD_DIR/$2" ]]
        ;;
    is-failed)
        printf 'active\n'
        exit 1
        ;;
esac
MOCK
chmod +x "$mockbin/systemctl"
cat > "$mockbin/journalctl" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "journalctl $*" >> "$JOURNALCTL_LOG"
unit=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -u)
            unit="$2"
            shift
            ;;
    esac
    shift
done
printf '%s\n' "mock journal for ${unit:-unknown}"
MOCK
chmod +x "$mockbin/journalctl"
cat > "$mockbin/curl" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CURL_LOG"
printf '203.0.113.9\n'
MOCK
chmod +x "$mockbin/curl"
cat > "$mockbin/autossh" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$AUTOSSH_LOG"
MOCK
chmod +x "$mockbin/autossh"
cat > "$mockbin/gost" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GOST_LOG"
MOCK
chmod +x "$mockbin/gost"
cat > "$mockbin/easytier-core" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$EASYTIER_LOG"
MOCK
chmod +x "$mockbin/easytier-core"
cat > "$mockbin/aliyun" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$ALIYUN_LOG"
arg_value() {
    local key="$1"
    shift
    while [[ $# -gt 0 ]]; do
        if [[ "$1" == "$key" ]]; then
            printf '%s\n' "$2"
            return
        fi
        shift
    done
}

print_firewall_rules() {
    local first=1
    printf '{"FirewallRules":['
    if [[ -n "${ALIYUN_STATE:-}" && -f "$ALIYUN_STATE" ]]; then
        while IFS='|' read -r id protocol port cidr policy remark; do
            [[ -n "$id" ]] || continue
            [[ "$first" == "1" ]] || printf ','
            first=0
            printf '{"Policy":"%s","Port":"%s","Remark":"%s","RuleId":"%s","RuleProtocol":"%s","SourceCidrIp":"%s"}' \
                "$policy" "$port" "$remark" "$id" "$protocol" "$cidr"
        done < "$ALIYUN_STATE"
    fi
    printf '],"PageNumber":1,"PageSize":10,"RequestId":"ok","TotalCount":0}\n'
}

case "$*" in
    *list-firewall-rules*)
        print_firewall_rules
        ;;
    *create-firewall-rule*)
        id="rule-$(date +%s%N)"
        protocol="$(arg_value --rule-protocol "$@")"
        port="$(arg_value --port "$@")"
        remark="$(arg_value --remark "$@")"
        printf '%s|%s|%s|0.0.0.0/0|accept|%s\n' "$id" "$protocol" "$port" "$remark" >> "${ALIYUN_STATE:?ALIYUN_STATE must be set}"
        printf '{"RuleId":"%s","RequestId":"ok"}\n' "$id"
        ;;
    *modify-firewall-rule*)
        tmp="${ALIYUN_STATE:?ALIYUN_STATE must be set}.tmp"
        rule_id="$(arg_value --rule-id "$@")"
        protocol="$(arg_value --rule-protocol "$@")"
        port="$(arg_value --port "$@")"
        cidr="$(arg_value --source-cidr-ip "$@")"
        new_remark="$(arg_value --remark "$@")"
        while IFS='|' read -r id old_protocol old_port old_cidr policy remark; do
            if [[ "$id" == "$rule_id" ]]; then
                [[ -n "$new_remark" ]] && remark="$new_remark"
                printf '%s|%s|%s|%s|%s|%s\n' "$id" "$protocol" "$port" "$cidr" "$policy" "$remark"
            else
                printf '%s|%s|%s|%s|%s|%s\n' "$id" "$old_protocol" "$old_port" "$old_cidr" "$policy" "$remark"
            fi
        done < "$ALIYUN_STATE" > "$tmp"
        mv "$tmp" "$ALIYUN_STATE"
        printf '{"RequestId":"ok"}\n'
        ;;
    *enable-firewall-rule*|*disable-firewall-rule*)
        tmp="${ALIYUN_STATE:?ALIYUN_STATE must be set}.tmp"
        rule_id="$(arg_value --rule-id "$@")"
        policy=accept
        [[ "$*" == *disable-firewall-rule* ]] && policy=drop
        while IFS='|' read -r id protocol port cidr old_policy remark; do
            if [[ "$id" == "$rule_id" ]]; then
                printf '%s|%s|%s|%s|%s|%s\n' "$id" "$protocol" "$port" "$cidr" "$policy" "$remark"
            else
                printf '%s|%s|%s|%s|%s|%s\n' "$id" "$protocol" "$port" "$cidr" "$old_policy" "$remark"
            fi
        done < "$ALIYUN_STATE" > "$tmp"
        mv "$tmp" "$ALIYUN_STATE"
        printf '{"RequestId":"ok"}\n'
        ;;
    *delete-firewall-rule*)
        tmp="${ALIYUN_STATE:?ALIYUN_STATE must be set}.tmp"
        rule_id="$(arg_value --rule-id "$@")"
        while IFS='|' read -r id protocol port cidr policy remark; do
            [[ "$id" == "$rule_id" ]] && continue
            printf '%s|%s|%s|%s|%s|%s\n' "$id" "$protocol" "$port" "$cidr" "$policy" "$remark"
        done < "$ALIYUN_STATE" > "$tmp"
        mv "$tmp" "$ALIYUN_STATE"
        printf '{"RequestId":"ok"}\n'
        ;;
    *DescribeSubDomainRecords*)
        printf '{"TotalCount":1,"DomainRecords":{"Record":[{"RR":"home","Type":"A","Line":"default","RecordId":"rid","Value":"203.0.113.1"}]}}\n'
        ;;
    *UpdateDomainRecord*)
        printf '{"RequestId":"ok"}\n'
        ;;
esac
MOCK
chmod +x "$mockbin/aliyun"
cat > "$mockbin/tccli" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TCCLI_LOG"
case "$*" in
    *DescribeFirewallRules*)
        case "${TCCLI_MODE:-}" in
            stale)
                printf '{"FirewallRuleSet":[{"Protocol":"TCP","Port":"22","CidrBlock":"203.0.113.7","Ipv6CidrBlock":"","Action":"ACCEPT","FirewallRuleDescription":"home-netops: test-rule-ssh"},{"Protocol":"TCP","Port":"8080","CidrBlock":"203.0.113.8/32","Ipv6CidrBlock":"","Action":"ACCEPT","FirewallRuleDescription":"home-netops: test-rule-web"},{"Protocol":"TCP","Port":"443","CidrBlock":"198.51.100.9","Ipv6CidrBlock":"","Action":"ACCEPT","FirewallRuleDescription":"home-netops: test-rule-office"},{"Protocol":"TCP","Port":"8443","CidrBlock":"203.0.113.7","Ipv6CidrBlock":"","Action":"ACCEPT","FirewallRuleDescription":"home-netops: obsolete-rule"},{"Protocol":"TCP","Port":"8080","CidrBlock":"203.0.113.8/32","Ipv6CidrBlock":"","Action":"ACCEPT","FirewallRuleDescription":"test-rule-web"},{"Protocol":"TCP","Port":"443","CidrBlock":"198.51.100.9","Ipv6CidrBlock":"","Action":"ACCEPT","FirewallRuleDescription":"test-rule-office"},{"Protocol":"TCP","Port":"8443","CidrBlock":"203.0.113.8/32","Ipv6CidrBlock":"","Action":"ACCEPT","FirewallRuleDescription":"manual-rule"}]}\n'
                ;;
            *)
                printf '{"FirewallRuleSet":[]}\n'
                ;;
        esac
        ;;
    *CreateFirewallRules*)
        printf '{"RequestId":"ok"}\n'
        ;;
    *)
        printf '{"RequestId":"ok"}\n'
        ;;
esac
MOCK
chmod +x "$mockbin/tccli"
cat > "$mockbin/ssh" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "ssh $*" >> "$SSH_LOG"
if [[ -n "${SSH_FAIL_RESTART_HOST:-}" ]] \
    && [[ "$*" == *"$SSH_FAIL_RESTART_HOST"* ]] \
    && [[ "$*" == *"sudo systemctl restart home-netops-easytier.service"* ]] \
    && [[ "$*" != *"sudo cp -p"* ]]; then
    exit 1
fi
MOCK
chmod +x "$mockbin/ssh"
cat > "$mockbin/scp" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "scp $*" >> "$SCP_LOG"
MOCK
chmod +x "$mockbin/scp"

toml_value() {
    awk -F '"' -v key="$2" '$0 ~ "^[[:space:]]*" key "[[:space:]]*=" {print $2; exit}' "$1"
}

test_config="$TMP/home-netops.json"
cat > "$test_config" <<CONF
{
  "shared": {
    "PUBLIC_IP_URLS": "https://example.invalid/ip",
    "PUBLIC_IP_TIMEOUT": "8",
    "PUBLIC_IP_NO_PROXY": "1",
    "UNUSED_SHARED_MARKER": "shared"
  },
  "services": {
    "ddns": {
      "ALIYUN_BIN": "aliyun",
      "ALIYUN_PROFILE": "ddns",
      "ALIYUN_DOMAIN_NAME": "bigbug.ren",
      "ALIYUN_RR": "home",
      "ALIYUN_TYPE": "A",
      "ALIYUN_LINE": "default",
      "ALIYUN_TTL": "600"
    },
    "firewall": {
      "TCCLI_BIN": "tccli",
      "TENCENT_INSTANCE_ID": "ins-test",
      "TENCENT_REGION": "ap-test",
      "TENCENT_FIREWALL_RULE_DESC_PREFIX": "home-netops: ",
      "TENCENT_FIREWALL_RULES": [
        {
          "Protocol": "TCP",
          "Port": "22",
          "Action": "ACCEPT",
          "FirewallRuleDescription": "test-rule-ssh"
        },
        {
          "Protocol": "TCP",
          "Port": "8080",
          "Action": "ACCEPT",
          "FirewallRuleDescription": "test-rule-web"
        },
        {
          "Protocol": "TCP",
          "Port": "443",
          "CidrBlock": "198.51.100.10",
          "Action": "ACCEPT",
          "FirewallRuleDescription": "test-rule-office"
        }
      ],
      "SYSTEMCTL_BIN": "systemctl"
    },
    "tencent-firewall": {
      "TCCLI_BIN": "tccli",
      "TENCENT_INSTANCE_ID": "ins-test",
      "TENCENT_REGION": "ap-test",
      "TENCENT_FIREWALL_RULE_DESC_PREFIX": "home-netops: ",
      "TENCENT_FIREWALL_RULES": [
        {
          "Protocol": "TCP",
          "Port": "22",
          "Action": "ACCEPT",
          "FirewallRuleDescription": "test-rule-ssh"
        },
        {
          "Protocol": "TCP",
          "Port": "8080",
          "Action": "ACCEPT",
          "FirewallRuleDescription": "test-rule-web"
        },
        {
          "Protocol": "TCP",
          "Port": "443",
          "CidrBlock": "198.51.100.10",
          "Action": "ACCEPT",
          "FirewallRuleDescription": "test-rule-office"
        }
      ],
      "SYSTEMCTL_BIN": "systemctl"
    },
    "aliyun-firewall": {
      "ALIYUN_BIN": "aliyun",
      "ALIYUN_FIREWALL_PROFILE": "firewall",
      "ALIYUN_INSTANCE_ID": "swas-test",
      "ALIYUN_BIZ_REGION_ID": "us-west",
      "ALIYUN_FIREWALL_RULES": [
        {
          "RuleProtocol": "TCP",
          "Port": "22",
          "Policy": "accept",
          "Remark": "test-rule-ssh"
        },
        {
          "RuleProtocol": "TCP",
          "Port": "22",
          "SourceCidrIp": "198.51.100.10",
          "Policy": "accept",
          "Remark": "test-rule-office-ssh"
        },
        {
          "RuleProtocol": "UDP",
          "Port": "11010",
          "SourceCidrIp": "198.51.100.11",
          "Policy": "drop",
          "Remark": "test-rule-easytier"
        }
      ],
      "SYSTEMCTL_BIN": "systemctl"
    },
    "reverse-ssh": {
      "AUTOSSH_BIN": "autossh",
      "CLOUD_HOST": "198.51.100.44",
      "CLOUD_USER": "deploy",
      "CLOUD_PORT": "22022",
      "REMOTE_BIND_ADDR": "127.0.0.1",
      "REMOTE_BIND_PORT": "2222",
      "LOCAL_TARGET_HOST": "127.0.0.1",
      "LOCAL_TARGET_PORT": "22",
      "CHECK_LOCAL_SSHD": "0"
    },
    "easytier": {
      "EASYTIER_BIN": "easytier-core"
    },
    "proxy-server": {
      "GOST_BIN": "gost",
      "PROXY_SOCKS_PORT": "1080",
      "PROXY_HTTP_PORT": "8080",
      "PROXY_SERVER_ONLY_MARKER": "must-not-load-for-tencent"
    },
    "proxy-client": {
      "GOST_BIN": "gost",
      "PROXY_CLIENT_LISTEN_ADDR": "127.0.0.1",
      "PROXY_SERVER_IP": "10.144.144.3",
      "PROXY_SOCKS_PORT": "1080",
      "PROXY_HTTP_PORT": "8080"
    }
  },
  "roles": {
    "home": {
      "services": ["ddns", "firewall", "reverse-ssh", "easytier"],
      "overrides": {
        "easytier": {
          "EASYTIER_CONFIG": "config/easytier-home.yaml"
        }
      }
    },
    "ali": {
      "services": ["easytier", "proxy-server"],
      "overrides": {
        "easytier": {
          "EASYTIER_CONFIG": "config/easytier-ali.yaml"
        }
      }
    },
    "tencent": {
      "services": ["easytier"],
      "overrides": {
        "easytier": {
          "EASYTIER_CONFIG": "config/easytier-tencent.yaml"
        }
      }
    },
    "ali-firewall": {
      "services": ["aliyun-firewall", "easytier"],
      "overrides": {
        "easytier": {
          "EASYTIER_CONFIG": "config/easytier-ali.yaml"
        }
      }
    },
    "dual-firewall": {
      "services": ["tencent-firewall", "aliyun-firewall", "easytier"],
      "overrides": {
        "easytier": {
          "EASYTIER_CONFIG": "config/easytier-home.yaml"
        }
      }
    },
    "client": {
      "services": ["proxy-client"],
      "overrides": {}
    }
  }
}
CONF

rotate_out="$TMP/rotate-out"
PATH="$mockbin:$PATH" \
"$ROOT/tools/rotate-easytier-secrets.sh" --dry-run --output-dir "$rotate_out" >/tmp/home-netops-rotate-dry-run.out
assert_file "$rotate_out/easytier-home.yaml"
assert_file "$rotate_out/easytier-ali.yaml"
assert_file "$rotate_out/easytier-tencent.yaml"
home_secret="$(toml_value "$rotate_out/easytier-home.yaml" network_secret)"
ali_secret="$(toml_value "$rotate_out/easytier-ali.yaml" network_secret)"
tencent_secret="$(toml_value "$rotate_out/easytier-tencent.yaml" network_secret)"
[[ "$home_secret" == "$ali_secret" && "$ali_secret" == "$tencent_secret" ]] || \
    fail "rotated configs must share one network_secret"
home_private="$(toml_value "$rotate_out/easytier-home.yaml" local_private_key)"
ali_private="$(toml_value "$rotate_out/easytier-ali.yaml" local_private_key)"
tencent_private="$(toml_value "$rotate_out/easytier-tencent.yaml" local_private_key)"
[[ "$home_private" != "$ali_private" && "$home_private" != "$tencent_private" && "$ali_private" != "$tencent_private" ]] || \
    fail "rotated roles must get distinct private keys"
tencent_public="$(toml_value "$rotate_out/easytier-tencent.yaml" local_public_key)"
home_peer="$(toml_value "$rotate_out/easytier-home.yaml" peer_public_key)"
ali_peer="$(toml_value "$rotate_out/easytier-ali.yaml" peer_public_key)"
[[ "$home_peer" == "$tencent_public" && "$ali_peer" == "$tencent_public" ]] || \
    fail "home and ali must pin the rotated tencent public key"
if grep -R 'REPLACE_WITH_ROTATED' "$rotate_out" >/dev/null 2>&1; then
    fail "rotated configs must not contain placeholder secrets"
fi

deploy_hosts="$TMP/deploy-hosts.json"
cat > "$deploy_hosts" <<CONF
{
  "roles": {
    "home": {
      "ssh_host": "home.example",
      "ssh_user": "root",
      "ssh_port": "2201",
      "app_home": "/srv/home-netops",
      "easytier_config": "config/easytier-home.local.yaml"
    },
    "ali": {
      "ssh_host": "ali.example",
      "ssh_user": "root",
      "ssh_port": "2202",
      "app_home": "/srv/home-netops",
      "easytier_config": "config/easytier-ali.local.yaml"
    },
    "tencent": {
      "ssh_host": "tencent.example",
      "ssh_user": "root",
      "ssh_port": "2203",
      "app_home": "/srv/home-netops",
      "easytier_config": "config/easytier-tencent.local.yaml"
    }
  }
}
CONF
SSH_LOG="$TMP/ssh-rotate.log" \
SCP_LOG="$TMP/scp-rotate.log" \
PATH="$mockbin:$PATH" \
"$ROOT/tools/rotate-easytier-secrets.sh" --apply --hosts "$deploy_hosts" --output-dir "$TMP/rotate-apply" >/tmp/home-netops-rotate-apply.out
assert_grep 'scp -P 2201' "$TMP/scp-rotate.log" "rotate apply must upload home config"
assert_grep 'scp -P 2202' "$TMP/scp-rotate.log" "rotate apply must upload ali config"
assert_grep 'scp -P 2203' "$TMP/scp-rotate.log" "rotate apply must upload tencent config"
assert_grep 'sudo install -m 0600' "$TMP/ssh-rotate.log" "rotate apply must stage configs with restricted permissions"
assert_grep 'sudo rm -f' "$TMP/ssh-rotate.log" "rotate apply must delete per-run backups after successful restart"
restart_lines="$(grep -n 'sudo systemctl restart home-netops-easytier.service' "$TMP/ssh-rotate.log" | cut -d: -f1 | tr '\n' ' ')"
set -- $restart_lines
[[ $# -eq 3 ]] || fail "rotate apply must restart exactly three EasyTier units"
first_restart="$(sed -n "${1}p" "$TMP/ssh-rotate.log")"
second_restart="$(sed -n "${2}p" "$TMP/ssh-rotate.log")"
third_restart="$(sed -n "${3}p" "$TMP/ssh-rotate.log")"
case "$first_restart:$second_restart:$third_restart" in
    *tencent.example*:*ali.example*:*home.example*)
        ;;
    *)
        fail "rotate apply must restart tencent, then ali, then home"
        ;;
esac
SSH_LOG="$TMP/ssh-rotate-rollback.log" \
SCP_LOG="$TMP/scp-rotate-rollback.log" \
SSH_FAIL_RESTART_HOST="ali.example" \
PATH="$mockbin:$PATH" \
"$ROOT/tools/rotate-easytier-secrets.sh" --apply --hosts "$deploy_hosts" --output-dir "$TMP/rotate-rollback" >/tmp/home-netops-rotate-rollback.out 2>&1 && \
    fail "rotate apply must fail when a remote restart fails"
assert_grep 'rolling back committed configs' /tmp/home-netops-rotate-rollback.out \
    "rotate apply must report rollback on restart failure"
assert_grep 'sudo cp -p' "$TMP/ssh-rotate-rollback.log" \
    "rotate apply must restore backups during rollback"

CURL_LOG="$TMP/curl.log" \
PATH="$mockbin:$PATH" \
HOME_NETOPS_CONFIG="$test_config" \
HOME_NETOPS_ROLE="home" \
HOME_NETOPS_APP_HOME="$ROOT" \
PUBLIC_IP_URLS="https://override.invalid/ip" \
http_proxy="http://proxy.invalid:8080" \
https_proxy="http://proxy.invalid:8080" \
all_proxy="socks5://proxy.invalid:1080" \
"$ROOT/lib/get-public-ip.sh" >/dev/null
assert_grep 'https://override.invalid/ip' "$TMP/curl.log" "environment variables must override JSON config"
assert_grep '--noproxy \*' "$TMP/curl.log" "public IP lookup must bypass proxy by default"

AUTOSSH_LOG="$TMP/autossh.log" \
PATH="$mockbin:$PATH" \
HOME_NETOPS_CONFIG="$test_config" \
HOME_NETOPS_ROLE="home" \
HOME_NETOPS_APP_HOME="$ROOT" \
"$ROOT/lib/reverse-ssh.sh"
assert_grep '-p 22022' "$TMP/autossh.log" "reverse SSH must use configured cloud SSH port"
assert_grep '-R 127.0.0.1:2222:127.0.0.1:22' "$TMP/autossh.log" "reverse SSH must use configured tunnel bind"
assert_grep 'deploy@198.51.100.44' "$TMP/autossh.log" "reverse SSH must use configured cloud host"

if PATH="$mockbin:$PATH" \
    HOME_NETOPS_CONFIG="$test_config" \
    HOME_NETOPS_ROLE="tencent" \
    HOME_NETOPS_APP_HOME="$ROOT" \
    bash -c '. "$1/lib/common.sh"; load_config; [[ -z "${PROXY_SERVER_ONLY_MARKER+x}" ]]' _ "$ROOT"; then
    :
else
    fail "disabled service config must not be loaded"
fi

resolved_tccli="$(HOME_NETOPS_APP_HOME="$ROOT" bash -c '. "$1/lib/common.sh"; resolve_command_path ".venv/bin/tccli"' _ "$ROOT")"
[[ "$resolved_tccli" == "$ROOT/.venv/bin/tccli" ]] || fail "relative command paths must resolve from app home"

EASYTIER_LOG="$TMP/easytier.log" \
PATH="$mockbin:$PATH" \
HOME_NETOPS_CONFIG="$test_config" \
HOME_NETOPS_ROLE="ali" \
HOME_NETOPS_APP_HOME="$ROOT" \
"$ROOT/lib/easytier.sh"
assert_grep "--config-file $ROOT/config/easytier-ali.yaml" "$TMP/easytier.log" \
    "EasyTier must resolve config relative to app home"

GOST_LOG="$TMP/gost.log" \
PATH="$mockbin:$PATH" \
HOME_NETOPS_CONFIG="$test_config" \
HOME_NETOPS_ROLE="ali" \
HOME_NETOPS_APP_HOME="$ROOT" \
"$ROOT/lib/proxy-server.sh"
assert_grep '-L socks5://10.144.144.3:1080' "$TMP/gost.log" \
    "proxy server must bind SOCKS to EasyTier IP from config file"
assert_grep '-L http://10.144.144.3:8080' "$TMP/gost.log" \
    "proxy server must bind HTTP to EasyTier IP from config file"

home_root="$TMP/home-root"
mkdir -p "$home_root/systemd"
SYSTEMD_DIR="$home_root/systemd" \
SYSTEMCTL_LOG="$TMP/systemctl-home.log" \
PATH="$mockbin:$PATH" \
HOME_NETOPS_SYSTEMD_DIR="$home_root/systemd" \
HOME_NETOPS_SYSTEMCTL="systemctl" \
HOME_NETOPS_ALLOW_NON_ROOT=1 \
"$ROOT/install.sh" --role home --config "$test_config" --app-home "$ROOT" --no-start
assert_file "$home_root/systemd/home-netops-aliyun-ddns.service"
assert_file "$home_root/systemd/home-netops-aliyun-ddns.timer"
assert_file "$home_root/systemd/home-netops-tencent-firewall.service"
assert_file "$home_root/systemd/home-netops-tencent-firewall.timer"
assert_file "$home_root/systemd/home-netops-reverse-ssh.service"
assert_file "$home_root/systemd/home-netops-easytier.service"
assert_not_file "$home_root/systemd/home-netops-proxy-server.service"
assert_grep "Environment=HOME_NETOPS_ROLE=home" "$home_root/systemd/home-netops-easytier.service" \
    "units must include role environment"
assert_grep "Environment=HOME_NETOPS_CONFIG=$test_config" "$home_root/systemd/home-netops-easytier.service" \
    "units must include config environment"
assert_grep "Environment=HOME_NETOPS_APP_HOME=$ROOT" "$home_root/systemd/home-netops-easytier.service" \
    "units must include app home environment"
assert_grep "ExecStart=$ROOT/lib/easytier.sh" "$home_root/systemd/home-netops-easytier.service" \
    "units must point to app-home script"
assert_grep 'Requires=home-netops-tencent-firewall.service' "$home_root/systemd/home-netops-easytier.service" \
    "home EasyTier must start after firewall"
assert_grep 'systemctl daemon-reload' "$TMP/systemctl-home.log" "install must reload systemd"
assert_not_file "$home_root/lib/home-netops"
assert_not_file "$home_root/etc/home-netops"

ali_root="$TMP/ali-root"
mkdir -p "$ali_root/systemd"
SYSTEMD_DIR="$ali_root/systemd" \
SYSTEMCTL_LOG="$TMP/systemctl-ali.log" \
PATH="$mockbin:$PATH" \
HOME_NETOPS_SYSTEMD_DIR="$ali_root/systemd" \
HOME_NETOPS_SYSTEMCTL="systemctl" \
HOME_NETOPS_ALLOW_NON_ROOT=1 \
"$ROOT/install.sh" --role ali --config "$test_config" --app-home "$ROOT"
assert_file "$ali_root/systemd/home-netops-easytier.service"
assert_file "$ali_root/systemd/home-netops-proxy-server.service"
assert_not_file "$ali_root/systemd/home-netops-aliyun-ddns.service"
assert_not_file "$ali_root/systemd/home-netops-tencent-firewall.service"
if grep -q 'home-netops-tencent-firewall.service' "$ali_root/systemd/home-netops-easytier.service"; then
    fail "ali EasyTier must not require Tencent firewall"
fi
assert_grep 'enable --now home-netops-easytier.service' "$TMP/systemctl-ali.log" \
    "ali install must enable EasyTier"
assert_grep 'enable --now home-netops-proxy-server.service' "$TMP/systemctl-ali.log" \
    "ali install must enable proxy server"

tencent_root="$TMP/tencent-root"
mkdir -p "$tencent_root/systemd"
SYSTEMD_DIR="$tencent_root/systemd" \
SYSTEMCTL_LOG="$TMP/systemctl-tencent.log" \
PATH="$mockbin:$PATH" \
HOME_NETOPS_SYSTEMD_DIR="$tencent_root/systemd" \
HOME_NETOPS_SYSTEMCTL="systemctl" \
HOME_NETOPS_ALLOW_NON_ROOT=1 \
"$ROOT/install.sh" --role tencent --config "$test_config" --app-home "$ROOT" --no-start
assert_file "$tencent_root/systemd/home-netops-easytier.service"
assert_not_file "$tencent_root/systemd/home-netops-proxy-server.service"
assert_not_file "$tencent_root/systemd/home-netops-tencent-firewall.service"

ali_firewall_root="$TMP/ali-firewall-root"
mkdir -p "$ali_firewall_root/systemd"
SYSTEMD_DIR="$ali_firewall_root/systemd" \
SYSTEMCTL_LOG="$TMP/systemctl-ali-firewall.log" \
PATH="$mockbin:$PATH" \
HOME_NETOPS_SYSTEMD_DIR="$ali_firewall_root/systemd" \
HOME_NETOPS_SYSTEMCTL="systemctl" \
HOME_NETOPS_ALLOW_NON_ROOT=1 \
"$ROOT/install.sh" --role ali-firewall --config "$test_config" --app-home "$ROOT" --no-start
assert_file "$ali_firewall_root/systemd/home-netops-aliyun-firewall.service"
assert_file "$ali_firewall_root/systemd/home-netops-aliyun-firewall.timer"
assert_not_file "$ali_firewall_root/systemd/home-netops-tencent-firewall.service"
assert_grep "ExecStart=$ROOT/firewall/aliyun.sh" "$ali_firewall_root/systemd/home-netops-aliyun-firewall.service" \
    "Aliyun firewall unit must run Aliyun firewall entrypoint"
assert_grep 'Requires=home-netops-aliyun-firewall.service' "$ali_firewall_root/systemd/home-netops-easytier.service" \
    "Aliyun firewall EasyTier role must start after Aliyun firewall"

dual_firewall_root="$TMP/dual-firewall-root"
mkdir -p "$dual_firewall_root/systemd"
SYSTEMD_DIR="$dual_firewall_root/systemd" \
SYSTEMCTL_LOG="$TMP/systemctl-dual-firewall.log" \
PATH="$mockbin:$PATH" \
HOME_NETOPS_SYSTEMD_DIR="$dual_firewall_root/systemd" \
HOME_NETOPS_SYSTEMCTL="systemctl" \
HOME_NETOPS_ALLOW_NON_ROOT=1 \
"$ROOT/install.sh" --role dual-firewall --config "$test_config" --app-home "$ROOT" --no-start
assert_file "$dual_firewall_root/systemd/home-netops-tencent-firewall.service"
assert_file "$dual_firewall_root/systemd/home-netops-tencent-firewall.timer"
assert_file "$dual_firewall_root/systemd/home-netops-aliyun-firewall.service"
assert_file "$dual_firewall_root/systemd/home-netops-aliyun-firewall.timer"
assert_grep "ExecStart=$ROOT/firewall/tencent.sh" "$dual_firewall_root/systemd/home-netops-tencent-firewall.service" \
    "Dual firewall role must install Tencent firewall entrypoint"
assert_grep "ExecStart=$ROOT/firewall/aliyun.sh" "$dual_firewall_root/systemd/home-netops-aliyun-firewall.service" \
    "Dual firewall role must install Aliyun firewall entrypoint"
assert_grep 'Requires=home-netops-tencent-firewall.service home-netops-aliyun-firewall.service' "$dual_firewall_root/systemd/home-netops-easytier.service" \
    "Dual firewall EasyTier role must require both firewall services"
assert_grep 'After=network-online.target home-netops-tencent-firewall.service home-netops-aliyun-firewall.service' "$dual_firewall_root/systemd/home-netops-easytier.service" \
    "Dual firewall EasyTier role must start after both firewall services"

client_root="$TMP/client-root"
client_bashrc="$TMP/client-home/.bashrc"
mkdir -p "$client_root/systemd" "$(dirname "$client_bashrc")"
printf '%s\n' '# user bashrc line' > "$client_bashrc"
SYSTEMD_DIR="$client_root/systemd" \
SYSTEMCTL_LOG="$TMP/systemctl-client.log" \
PATH="$mockbin:$PATH" \
HOME_NETOPS_SYSTEMD_DIR="$client_root/systemd" \
HOME_NETOPS_SYSTEMCTL="systemctl" \
HOME_NETOPS_ALLOW_NON_ROOT=1 \
HOME_NETOPS_BASHRC="$client_bashrc" \
"$ROOT/install.sh" --role client --config "$test_config" --app-home "$ROOT" --no-start
assert_grep '# user bashrc line' "$client_bashrc" "proxy-client install must preserve existing bashrc content"
assert_grep '# home-netops proxy-client start' "$client_bashrc" "proxy-client install must write managed start marker"
assert_grep 'export ALL_PROXY=http://127.0.0.1:8080' "$client_bashrc" "proxy-client must write local ALL_PROXY"
assert_grep 'export all_proxy=http://127.0.0.1:8080' "$client_bashrc" "proxy-client must write local all_proxy"
assert_grep 'export HTTP_PROXY=http://127.0.0.1:8080' "$client_bashrc" "proxy-client must write local HTTP_PROXY"
assert_grep 'export HTTPS_PROXY=http://127.0.0.1:8080' "$client_bashrc" "proxy-client must write local HTTPS_PROXY"
assert_grep 'export http_proxy=http://127.0.0.1:8080' "$client_bashrc" "proxy-client must write local http_proxy"
assert_grep 'export https_proxy=http://127.0.0.1:8080' "$client_bashrc" "proxy-client must write local https_proxy"
assert_file "$client_root/systemd/home-netops-proxy-client.service"
assert_grep "ExecStart=$ROOT/lib/proxy-client.sh" "$client_root/systemd/home-netops-proxy-client.service" \
    "proxy-client unit must run proxy-client entrypoint"
if grep -q 'enable --now' "$TMP/systemctl-client.log"; then
    fail "proxy-client --no-start install must not enable systemd units"
fi

SYSTEMD_DIR="$client_root/systemd" \
SYSTEMCTL_LOG="$TMP/systemctl-client-2.log" \
PATH="$mockbin:$PATH" \
HOME_NETOPS_SYSTEMD_DIR="$client_root/systemd" \
HOME_NETOPS_SYSTEMCTL="systemctl" \
HOME_NETOPS_ALLOW_NON_ROOT=1 \
HOME_NETOPS_BASHRC="$client_bashrc" \
"$ROOT/install.sh" --role client --config "$test_config" --app-home "$ROOT" --no-start
marker_count="$(grep -c '^# home-netops proxy-client start$' "$client_bashrc")"
[[ "$marker_count" == "1" ]] || fail "proxy-client install must replace the managed block instead of appending duplicates"

if HOME_NETOPS_ALLOW_NON_ROOT=1 "$ROOT/install.sh" --services all --no-start >/dev/null 2>&1; then
    fail "--services must not be supported"
fi

if HOME_NETOPS_ALLOW_NON_ROOT=1 "$ROOT/install.sh" --interactive --no-start >/dev/null 2>&1; then
    fail "--interactive must not be supported"
fi

if HOME_NETOPS_ALLOW_NON_ROOT=1 "$ROOT/install.sh" --config "$test_config" --no-start >/dev/null 2>&1; then
    fail "install without role must fail"
fi

bad_config="$TMP/bad.json"
cat > "$bad_config" <<'CONF'
{
  "roles": {
    "bad": {
      "services": ["proxy-server"],
      "overrides": {}
    }
  }
}
CONF
if HOME_NETOPS_ALLOW_NON_ROOT=1 "$ROOT/install.sh" --role bad --config "$bad_config" --app-home "$ROOT" --no-start >/dev/null 2>&1; then
    fail "proxy-server without easytier must fail"
fi

bad_service_config="$TMP/bad-service.json"
cat > "$bad_service_config" <<'CONF'
{
  "roles": {
    "bad": {
      "services": ["bogus"],
      "overrides": {}
    }
  }
}
CONF
if HOME_NETOPS_ALLOW_NON_ROOT=1 "$ROOT/install.sh" --role bad --config "$bad_service_config" --app-home "$ROOT" --no-start >/dev/null 2>&1; then
    fail "unknown service must fail"
fi

bad_proxy_client_config="$TMP/bad-proxy-client.json"
cat > "$bad_proxy_client_config" <<'CONF'
{
  "services": {
    "proxy-client": {
      "PROXY_SOCKS_PORT": "1080",
      "PROXY_HTTP_PORT": "8080"
    }
  },
  "roles": {
    "bad": {
      "services": ["proxy-client"],
      "overrides": {}
    }
  }
}
CONF
if HOME_NETOPS_ALLOW_NON_ROOT=1 HOME_NETOPS_BASHRC="$TMP/bad-client.bashrc" "$ROOT/install.sh" --role bad --config "$bad_proxy_client_config" --app-home "$ROOT" --no-start >/dev/null 2>&1; then
    fail "proxy-client without PROXY_SERVER_IP must fail"
fi

SYSTEMD_DIR="$ali_root/systemd" \
SYSTEMCTL_LOG="$TMP/systemctl-check.log" \
PATH="$mockbin:$PATH" \
HOME_NETOPS_SYSTEMD_DIR="$ali_root/systemd" \
HOME_NETOPS_SYSTEMCTL="systemctl" \
"$ROOT/check.sh" --role ali --config "$test_config" --app-home "$ROOT" >/tmp/home-netops-check.out
assert_grep 'home-netops check passed: role=ali services=easytier proxy-server' /tmp/home-netops-check.out \
    "check must pass for installed ali role"

SYSTEMD_DIR="$ali_root/systemd" \
SYSTEMCTL_LOG="$TMP/systemctl-check-deep.log" \
JOURNALCTL_LOG="$TMP/journalctl-check-deep.log" \
PATH="$mockbin:$PATH" \
HOME_NETOPS_SYSTEMD_DIR="$ali_root/systemd" \
HOME_NETOPS_SYSTEMCTL="systemctl" \
HOME_NETOPS_JOURNALCTL="journalctl" \
EASYTIER_CONFIG="$rotate_out/easytier-ali.yaml" \
"$ROOT/check.sh" --role ali --config "$test_config" --app-home "$ROOT" --deep --no-network --logs 2 >/tmp/home-netops-check-deep.out
assert_grep '== Topology ==' /tmp/home-netops-check-deep.out \
    "deep check must group topology output"
assert_grep '  - role: ali' /tmp/home-netops-check-deep.out \
    "deep check must print role topology"
assert_grep '  - proxy-server -> deps: easytier; units: home-netops-proxy-server.service' /tmp/home-netops-check-deep.out \
    "deep check must print service dependencies"
assert_grep '  - skip network probe proxy-server-socks 10.144.144.3:1080' /tmp/home-netops-check-deep.out \
    "deep check --no-network must skip proxy-server network probe"
if [[ -e "$TMP/journalctl-check-deep.log" ]]; then
    fail "deep check must not read journal logs for healthy units"
fi

SYSTEMD_DIR="$ali_root/systemd" \
SYSTEMCTL_LOG="$TMP/systemctl-check-service.log" \
JOURNALCTL_LOG="$TMP/journalctl-check-service.log" \
PATH="$mockbin:$PATH" \
HOME_NETOPS_SYSTEMD_DIR="$ali_root/systemd" \
HOME_NETOPS_SYSTEMCTL="systemctl" \
HOME_NETOPS_JOURNALCTL="journalctl" \
EASYTIER_CONFIG="$rotate_out/easytier-ali.yaml" \
"$ROOT/check.sh" --role ali --config "$test_config" --app-home "$ROOT" --deep --service proxy-server --no-network >/tmp/home-netops-check-service.out
assert_grep '== Service: proxy-server ==' /tmp/home-netops-check-service.out \
    "service-filtered deep check must diagnose selected service"
assert_not_grep '== Service: easytier ==' /tmp/home-netops-check-service.out \
    "service-filtered deep check must not diagnose other services"
if [[ -e "$TMP/journalctl-check-service.log" ]]; then
    fail "service-filtered deep check must not read journal logs for healthy units"
fi

SYSTEMD_DIR="$ali_root/systemd" \
SYSTEMCTL_LOG="$TMP/systemctl-check-service-bad.log" \
JOURNALCTL_LOG="$TMP/journalctl-check-service-bad.log" \
SYSTEMCTL_INACTIVE_UNIT="home-netops-proxy-server.service" \
PATH="$mockbin:$PATH" \
HOME_NETOPS_SYSTEMD_DIR="$ali_root/systemd" \
HOME_NETOPS_SYSTEMCTL="systemctl" \
HOME_NETOPS_JOURNALCTL="journalctl" \
EASYTIER_CONFIG="$rotate_out/easytier-ali.yaml" \
"$ROOT/check.sh" --role ali --config "$test_config" --app-home "$ROOT" --deep --service proxy-server --no-network >/tmp/home-netops-check-service-bad.out 2>&1 && \
    fail "service-filtered deep check must fail when selected service is inactive"
assert_grep 'journalctl -u home-netops-proxy-server.service -n 30 --no-pager' "$TMP/journalctl-check-service-bad.log" \
    "service-filtered deep check must read selected service journal logs when unhealthy"

SYSTEMD_DIR="$client_root/systemd" \
SYSTEMCTL_LOG="$TMP/systemctl-check-client.log" \
PATH="$mockbin:$PATH" \
HOME_NETOPS_SYSTEMD_DIR="$client_root/systemd" \
HOME_NETOPS_SYSTEMCTL="systemctl" \
HOME_NETOPS_BASHRC="$client_bashrc" \
"$ROOT/check.sh" --role client --config "$test_config" --app-home "$ROOT" >/tmp/home-netops-check-client.out
assert_grep 'proxy-client bashrc block' /tmp/home-netops-check-client.out \
    "check must validate proxy-client bashrc block"

GOST_LOG="$TMP/gost-client.log" \
PATH="$mockbin:$PATH" \
HOME_NETOPS_CONFIG="$test_config" \
HOME_NETOPS_ROLE="client" \
HOME_NETOPS_APP_HOME="$ROOT" \
"$ROOT/lib/proxy-client.sh"
assert_grep "-C $ROOT/config/gost.yaml" "$TMP/gost-client.log" \
    "proxy-client must start gost with the project config file"

missing_tool_bin="$TMP/missing-tool-bin"
mkdir -p "$missing_tool_bin"
ln -s "$(command -v jq)" "$missing_tool_bin/jq"
ln -s "$mockbin/systemctl" "$missing_tool_bin/systemctl"
ln -s "$mockbin/curl" "$missing_tool_bin/curl"
ln -s "$mockbin/easytier-core" "$missing_tool_bin/easytier-core"
if SYSTEMD_DIR="$ali_root/systemd" \
    SYSTEMCTL_LOG="$TMP/systemctl-check-missing.log" \
    PATH="$missing_tool_bin" \
    HOME_NETOPS_SYSTEMD_DIR="$ali_root/systemd" \
    HOME_NETOPS_SYSTEMCTL="systemctl" \
    "$ROOT/check.sh" --role ali --config "$test_config" --app-home "$ROOT" >/dev/null 2>&1; then
    fail "check must fail when gost is missing"
fi

mock_get_ip="$TMP/get-ip.sh"
cat > "$mock_get_ip" <<'MOCK'
#!/usr/bin/env bash
echo "203.0.113.7"
MOCK
chmod +x "$mock_get_ip"

TCCLI_LOG="$TMP/tccli.log" \
SYSTEMCTL_LOG="$TMP/systemctl-firewall.log" \
PATH="$mockbin:$PATH" \
HOME_NETOPS_CONFIG="$test_config" \
HOME_NETOPS_ROLE="home" \
HOME_NETOPS_APP_HOME="$ROOT" \
GET_IP_SCRIPT="$mock_get_ip" \
"$ROOT/firewall/tencent.sh"
assert_grep 'DescribeFirewallRules' "$TMP/tccli.log" "Tencent script must describe existing rules"
assert_grep 'CreateFirewallRules' "$TMP/tccli.log" "Tencent script must create missing rule"
create_count="$(grep -c 'CreateFirewallRules' "$TMP/tccli.log")"
[[ "$create_count" == "3" ]] || fail "Tencent script must create all missing managed rules"
assert_grep '203.0.113.7' "$TMP/tccli.log" "Tencent script must use current public IP"
assert_grep '198.51.100.10' "$TMP/tccli.log" "Tencent script must use configured static CIDR"
assert_grep '"Port":"22"' "$TMP/tccli.log" "Tencent script must create SSH firewall rule"
assert_grep '"Port":"8080"' "$TMP/tccli.log" "Tencent script must create web firewall rule"
assert_grep '"Port":"443"' "$TMP/tccli.log" "Tencent script must create static firewall rule"
assert_grep 'home-netops: test-rule-ssh' "$TMP/tccli.log" "Tencent script must add managed description prefix"
assert_grep 'home-netops: test-rule-web' "$TMP/tccli.log" "Tencent script must add managed description prefix to each rule"
assert_grep 'home-netops: test-rule-office' "$TMP/tccli.log" "Tencent script must add managed description prefix to static rules"
if grep -q '203.0.113.7/32' "$TMP/tccli.log"; then
    fail "Tencent script must not append /32 to single IP rules"
fi
assert_grep 'try-restart home-netops-reverse-ssh.service' "$TMP/systemctl-firewall.log" \
    "Tencent script must restart reverse SSH when firewall changes"

TCCLI_LOG="$TMP/tccli-stale.log" \
SYSTEMCTL_LOG="$TMP/systemctl-firewall-stale.log" \
TCCLI_MODE="stale" \
PATH="$mockbin:$PATH" \
HOME_NETOPS_CONFIG="$test_config" \
HOME_NETOPS_ROLE="home" \
HOME_NETOPS_APP_HOME="$ROOT" \
GET_IP_SCRIPT="$mock_get_ip" \
"$ROOT/firewall/tencent.sh"
assert_grep 'DeleteFirewallRules' "$TMP/tccli-stale.log" "Tencent script must delete stale rules"
delete_count="$(grep -c 'DeleteFirewallRules' "$TMP/tccli-stale.log")"
[[ "$delete_count" == "3" ]] || fail "Tencent script must delete stale and obsolete managed rules"
if grep 'DeleteFirewallRules' "$TMP/tccli-stale.log" | grep -q 'Ipv6CidrBlock'; then
    fail "Tencent stale-rule delete must omit empty Ipv6CidrBlock"
fi
assert_grep 'CreateFirewallRules' "$TMP/tccli-stale.log" "Tencent script must create replacement rule after stale delete"
stale_create_count="$(grep -c 'CreateFirewallRules' "$TMP/tccli-stale.log")"
[[ "$stale_create_count" == "2" ]] || fail "Tencent stale-rule sync must create only missing managed rules"
assert_grep '"Port":"8080"' "$TMP/tccli-stale.log" "Tencent stale-rule sync must replace stale web rule"
assert_grep '"Port":"443"' "$TMP/tccli-stale.log" "Tencent stale-rule sync must replace stale static rule"
assert_grep '198.51.100.10' "$TMP/tccli-stale.log" "Tencent stale-rule sync must create configured static CIDR"
assert_grep 'home-netops: obsolete-rule' "$TMP/tccli-stale.log" "Tencent stale-rule sync must delete obsolete managed rule"
assert_not_grep 'DeleteFirewallRules.*"FirewallRuleDescription":"test-rule-web"' "$TMP/tccli-stale.log" \
    "Tencent stale-rule sync must not delete unprefixed manual rules"
assert_not_grep 'DeleteFirewallRules.*"FirewallRuleDescription":"test-rule-office"' "$TMP/tccli-stale.log" \
    "Tencent stale-rule sync must not delete unprefixed manual static rules"
assert_not_grep 'manual-rule.*DeleteFirewallRules\|DeleteFirewallRules.*manual-rule' "$TMP/tccli-stale.log" \
    "Tencent stale-rule sync must not delete unmanaged descriptions"

touch "$TMP/aliyun-fw.state"
ALIYUN_LOG="$TMP/aliyun-firewall.log" \
ALIYUN_STATE="$TMP/aliyun-fw.state" \
SYSTEMCTL_LOG="$TMP/systemctl-aliyun-firewall.log" \
PATH="$mockbin:$PATH" \
HOME_NETOPS_CONFIG="$test_config" \
HOME_NETOPS_ROLE="ali-firewall" \
HOME_NETOPS_APP_HOME="$ROOT" \
GET_IP_SCRIPT="$mock_get_ip" \
"$ROOT/firewall/aliyun.sh"
assert_grep 'list-firewall-rules' "$TMP/aliyun-firewall.log" "Aliyun firewall script must list existing rules"
aliyun_create_count="$(grep -c 'create-firewall-rule' "$TMP/aliyun-firewall.log")"
[[ "$aliyun_create_count" == "3" ]] || fail "Aliyun firewall script must create missing target rules"
aliyun_modify_count="$(grep -c 'modify-firewall-rule' "$TMP/aliyun-firewall.log")"
[[ "$aliyun_modify_count" == "3" ]] || fail "Aliyun firewall script must modify created rules to set CIDR and remark"
assert_grep '203.0.113.7' "$TMP/aliyun-firewall.log" "Aliyun firewall script must use current public IP"
assert_grep '198.51.100.10' "$TMP/aliyun-firewall.log" "Aliyun firewall script must use configured static CIDR"
assert_grep '198.51.100.11' "$TMP/aliyun-firewall.log" "Aliyun firewall script must keep distinct static CIDRs"
assert_grep '--remark home-netops: test-rule-ssh' "$TMP/aliyun-firewall.log" "Aliyun firewall script must set SSH rule remark"
assert_grep '--remark home-netops: test-rule-office-ssh' "$TMP/aliyun-firewall.log" "Aliyun firewall script must set same-port static rule remark"
assert_grep '--remark home-netops: test-rule-easytier' "$TMP/aliyun-firewall.log" "Aliyun firewall script must set EasyTier rule remark"
aliyun_tcp22_count="$(awk -F'|' '$2 == "TCP" && $3 == "22" { count++ } END { print count + 0 }' "$TMP/aliyun-fw.state")"
[[ "$aliyun_tcp22_count" == "2" ]] || fail "Aliyun firewall script must keep same protocol/port rules with different CIDRs"
assert_grep 'home-netops: test-rule-office-ssh' "$TMP/aliyun-fw.state" "Aliyun firewall state must persist same-port static rule remark"
assert_grep 'enable-firewall-rule' "$TMP/aliyun-firewall.log" "Aliyun firewall script must enable accept rules by RuleId"
assert_grep 'disable-firewall-rule' "$TMP/aliyun-firewall.log" "Aliyun firewall script must disable drop rules by RuleId"
assert_grep 'try-restart home-netops-reverse-ssh.service' "$TMP/systemctl-aliyun-firewall.log" \
    "Aliyun firewall script must restart reverse SSH when firewall changes"

ALIYUN_LOG="$TMP/aliyun.log" \
CURL_LOG="$TMP/curl-ddns.log" \
PATH="$mockbin:$PATH" \
HOME_NETOPS_CONFIG="$test_config" \
HOME_NETOPS_ROLE="home" \
HOME_NETOPS_APP_HOME="$ROOT" \
"$ROOT/ddns/aliyun.sh"
assert_grep 'DescribeSubDomainRecords' "$TMP/aliyun.log" "Aliyun script must query DNS records"
assert_grep 'UpdateDomainRecord' "$TMP/aliyun.log" "Aliyun script must update stale DNS record"

SYSTEMD_DIR="$ali_root/systemd" \
SYSTEMCTL_LOG="$TMP/systemctl-uninstall.log" \
PATH="$mockbin:$PATH" \
HOME_NETOPS_SYSTEMD_DIR="$ali_root/systemd" \
HOME_NETOPS_SYSTEMCTL="systemctl" \
HOME_NETOPS_ALLOW_NON_ROOT=1 \
HOME_NETOPS_BASHRC="$client_bashrc" \
"$ROOT/uninstall.sh" --yes
assert_not_file "$ali_root/systemd/home-netops-easytier.service"
assert_not_file "$ali_root/systemd/home-netops-proxy-server.service"
assert_grep 'disable --now home-netops-easytier.service' "$TMP/systemctl-uninstall.log" \
    "uninstall must stop EasyTier"
assert_grep 'disable --now home-netops-proxy-client.service' "$TMP/systemctl-uninstall.log" \
    "uninstall must stop proxy-client"
assert_grep '# user bashrc line' "$client_bashrc" "uninstall must preserve user bashrc content"
if grep -q 'home-netops proxy-client' "$client_bashrc"; then
    fail "uninstall must remove proxy-client managed bashrc block"
fi

if HOME_NETOPS_ALLOW_NON_ROOT=1 "$ROOT/uninstall.sh" --purge --yes >/dev/null 2>&1; then
    fail "--purge must not be supported"
fi

echo "PASS"

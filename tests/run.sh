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
        [[ -e "$SYSTEMD_DIR/$2" ]]
        ;;
esac
MOCK
chmod +x "$mockbin/systemctl"
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
case "$*" in
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
                printf '{"FirewallRuleSet":[{"Protocol":"TCP","Port":"22","CidrBlock":"203.0.113.7","Ipv6CidrBlock":"","Action":"ACCEPT","FirewallRuleDescription":"home-netops: test-rule-ssh"},{"Protocol":"TCP","Port":"8080","CidrBlock":"203.0.113.8/32","Ipv6CidrBlock":"","Action":"ACCEPT","FirewallRuleDescription":"home-netops: test-rule-web"},{"Protocol":"TCP","Port":"443","CidrBlock":"203.0.113.7","Ipv6CidrBlock":"","Action":"ACCEPT","FirewallRuleDescription":"home-netops: obsolete-rule"},{"Protocol":"TCP","Port":"8080","CidrBlock":"203.0.113.8/32","Ipv6CidrBlock":"","Action":"ACCEPT","FirewallRuleDescription":"test-rule-web"},{"Protocol":"TCP","Port":"443","CidrBlock":"203.0.113.8/32","Ipv6CidrBlock":"","Action":"ACCEPT","FirewallRuleDescription":"manual-rule"}]}\n'
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
[[ "$create_count" == "2" ]] || fail "Tencent script must create all missing managed rules"
assert_grep '203.0.113.7' "$TMP/tccli.log" "Tencent script must use current public IP"
assert_grep '"Port":"22"' "$TMP/tccli.log" "Tencent script must create SSH firewall rule"
assert_grep '"Port":"8080"' "$TMP/tccli.log" "Tencent script must create web firewall rule"
assert_grep 'home-netops: test-rule-ssh' "$TMP/tccli.log" "Tencent script must add managed description prefix"
assert_grep 'home-netops: test-rule-web' "$TMP/tccli.log" "Tencent script must add managed description prefix to each rule"
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
[[ "$delete_count" == "2" ]] || fail "Tencent script must delete stale and obsolete managed rules"
if grep 'DeleteFirewallRules' "$TMP/tccli-stale.log" | grep -q 'Ipv6CidrBlock'; then
    fail "Tencent stale-rule delete must omit empty Ipv6CidrBlock"
fi
assert_grep 'CreateFirewallRules' "$TMP/tccli-stale.log" "Tencent script must create replacement rule after stale delete"
stale_create_count="$(grep -c 'CreateFirewallRules' "$TMP/tccli-stale.log")"
[[ "$stale_create_count" == "1" ]] || fail "Tencent stale-rule sync must create only missing managed rules"
assert_grep '"Port":"8080"' "$TMP/tccli-stale.log" "Tencent stale-rule sync must replace stale web rule"
assert_grep 'home-netops: obsolete-rule' "$TMP/tccli-stale.log" "Tencent stale-rule sync must delete obsolete managed rule"
assert_not_grep 'DeleteFirewallRules.*"FirewallRuleDescription":"test-rule-web"' "$TMP/tccli-stale.log" \
    "Tencent stale-rule sync must not delete unprefixed manual rules"
assert_not_grep 'manual-rule.*DeleteFirewallRules\|DeleteFirewallRules.*manual-rule' "$TMP/tccli-stale.log" \
    "Tencent stale-rule sync must not delete unmanaged descriptions"

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

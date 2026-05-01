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

scripts=(
    ddns/aliyun.sh
    lib/common.sh
    lib/get-public-ip.sh
    install.sh
    reverse-ssh.sh
    firewall/tencent.sh
    uninstall.sh
)

for script in "${scripts[@]}"; do
    bash -n "$ROOT/$script"
done

bash -n "$ROOT/config/home-netops.conf.example"

grep -q 'Requires=home-netops-tencent-firewall.service' "$ROOT/systemd/home-netops-reverse-ssh.service" \
    || fail "reverse SSH service must require firewall service"
grep -q 'After=.*home-netops-tencent-firewall.service' "$ROOT/systemd/home-netops-reverse-ssh.service" \
    || fail "reverse SSH service must start after firewall service"
grep -q 'ExecStart=/usr/local/lib/home-netops/firewall/tencent.sh' "$ROOT/systemd/home-netops-tencent-firewall.service" \
    || fail "firewall service must run Tencent sync script"

mockbin="$TMP/bin"
mkdir -p "$mockbin"
cat > "$mockbin/systemctl" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "systemctl $*" >> "$SYSTEMCTL_LOG"
MOCK
chmod +x "$mockbin/systemctl"

install_root="$TMP/install-root"
mkdir -p "$install_root/etc" "$install_root/systemd"
SYSTEMCTL_LOG="$TMP/systemctl.log" \
PATH="$mockbin:$PATH" \
HOME_NETOPS_LIB_DIR="$install_root/lib/home-netops" \
HOME_NETOPS_ETC_DIR="$install_root/etc/home-netops" \
HOME_NETOPS_CONFIG="$install_root/etc/home-netops/home-netops.conf" \
HOME_NETOPS_SYSTEMD_DIR="$install_root/systemd" \
HOME_NETOPS_SYSTEMCTL="systemctl" \
HOME_NETOPS_ALLOW_NON_ROOT=1 \
"$ROOT/install.sh" --services all --no-start

assert_file "$install_root/lib/home-netops/ddns/aliyun.sh"
assert_file "$install_root/lib/home-netops/lib/get-public-ip.sh"
assert_file "$install_root/lib/home-netops/firewall/tencent.sh"
assert_file "$install_root/lib/home-netops/lib/common.sh"
assert_file "$install_root/lib/home-netops/reverse-ssh.sh"
assert_file "$install_root/etc/home-netops/home-netops.conf"
assert_file "$install_root/systemd/home-netops-aliyun-ddns.service"
assert_file "$install_root/systemd/home-netops-aliyun-ddns.timer"
assert_file "$install_root/systemd/home-netops-tencent-firewall.service"
assert_file "$install_root/systemd/home-netops-tencent-firewall.timer"
assert_file "$install_root/systemd/home-netops-reverse-ssh.service"
grep -q 'systemctl daemon-reload' "$TMP/systemctl.log" || fail "install must reload systemd"

echo '# user change' >> "$install_root/etc/home-netops/home-netops.conf"
SYSTEMCTL_LOG="$TMP/systemctl-2.log" \
PATH="$mockbin:$PATH" \
HOME_NETOPS_LIB_DIR="$install_root/lib/home-netops" \
HOME_NETOPS_ETC_DIR="$install_root/etc/home-netops" \
HOME_NETOPS_CONFIG="$install_root/etc/home-netops/home-netops.conf" \
HOME_NETOPS_SYSTEMD_DIR="$install_root/systemd" \
HOME_NETOPS_SYSTEMCTL="systemctl" \
HOME_NETOPS_ALLOW_NON_ROOT=1 \
"$ROOT/install.sh" --services all --no-start
grep -q '# user change' "$install_root/etc/home-netops/home-netops.conf" || fail "install must not overwrite config"

missing_scope_root="$TMP/missing-scope-root"
mkdir -p "$missing_scope_root/etc" "$missing_scope_root/systemd"
if SYSTEMCTL_LOG="$TMP/systemctl-missing-scope.log" \
    PATH="$mockbin:$PATH" \
    HOME_NETOPS_LIB_DIR="$missing_scope_root/lib/home-netops" \
    HOME_NETOPS_ETC_DIR="$missing_scope_root/etc/home-netops" \
    HOME_NETOPS_CONFIG="$missing_scope_root/etc/home-netops/home-netops.conf" \
    HOME_NETOPS_SYSTEMD_DIR="$missing_scope_root/systemd" \
    HOME_NETOPS_SYSTEMCTL="systemctl" \
    HOME_NETOPS_ALLOW_NON_ROOT=1 \
    "$ROOT/install.sh" --no-start >/dev/null 2>&1; then
    fail "install without explicit scope must fail in non-interactive use"
fi

ddns_root="$TMP/ddns-root"
mkdir -p "$ddns_root/etc" "$ddns_root/systemd"
SYSTEMCTL_LOG="$TMP/systemctl-ddns.log" \
PATH="$mockbin:$PATH" \
HOME_NETOPS_LIB_DIR="$ddns_root/lib/home-netops" \
HOME_NETOPS_ETC_DIR="$ddns_root/etc/home-netops" \
HOME_NETOPS_CONFIG="$ddns_root/etc/home-netops/home-netops.conf" \
HOME_NETOPS_SYSTEMD_DIR="$ddns_root/systemd" \
HOME_NETOPS_SYSTEMCTL="systemctl" \
HOME_NETOPS_ALLOW_NON_ROOT=1 \
"$ROOT/install.sh" --services ddns
assert_file "$ddns_root/systemd/home-netops-aliyun-ddns.service"
assert_file "$ddns_root/systemd/home-netops-aliyun-ddns.timer"
assert_not_file "$ddns_root/systemd/home-netops-tencent-firewall.service"
assert_not_file "$ddns_root/systemd/home-netops-tencent-firewall.timer"
assert_not_file "$ddns_root/systemd/home-netops-reverse-ssh.service"
grep -q 'enable --now home-netops-aliyun-ddns.timer' "$TMP/systemctl-ddns.log" \
    || fail "ddns install must enable ddns timer"
if grep -q 'home-netops-tencent-firewall' "$TMP/systemctl-ddns.log"; then
    fail "ddns install must not enable firewall units"
fi
if grep -q 'home-netops-reverse-ssh' "$TMP/systemctl-ddns.log"; then
    fail "ddns install must not enable reverse SSH"
fi

interactive_root="$TMP/interactive-root"
mkdir -p "$interactive_root/etc" "$interactive_root/systemd"
env \
    SYSTEMCTL_LOG="$TMP/systemctl-interactive.log" \
    PATH="$mockbin:$PATH" \
    HOME_NETOPS_LIB_DIR="$interactive_root/lib/home-netops" \
    HOME_NETOPS_ETC_DIR="$interactive_root/etc/home-netops" \
    HOME_NETOPS_CONFIG="$interactive_root/etc/home-netops/home-netops.conf" \
    HOME_NETOPS_SYSTEMD_DIR="$interactive_root/systemd" \
    HOME_NETOPS_SYSTEMCTL="systemctl" \
    HOME_NETOPS_ALLOW_NON_ROOT=1 \
    bash -c 'printf "firewall\n" | "$1" --interactive --no-start' _ "$ROOT/install.sh"
assert_file "$interactive_root/systemd/home-netops-tencent-firewall.service"
assert_file "$interactive_root/systemd/home-netops-tencent-firewall.timer"
assert_not_file "$interactive_root/systemd/home-netops-aliyun-ddns.service"
assert_not_file "$interactive_root/systemd/home-netops-reverse-ssh.service"

empty_interactive_root="$TMP/empty-interactive-root"
mkdir -p "$empty_interactive_root/etc" "$empty_interactive_root/systemd"
if env \
    SYSTEMCTL_LOG="$TMP/systemctl-empty-interactive.log" \
    PATH="$mockbin:$PATH" \
    HOME_NETOPS_LIB_DIR="$empty_interactive_root/lib/home-netops" \
    HOME_NETOPS_ETC_DIR="$empty_interactive_root/etc/home-netops" \
    HOME_NETOPS_CONFIG="$empty_interactive_root/etc/home-netops/home-netops.conf" \
    HOME_NETOPS_SYSTEMD_DIR="$empty_interactive_root/systemd" \
    HOME_NETOPS_SYSTEMCTL="systemctl" \
    HOME_NETOPS_ALLOW_NON_ROOT=1 \
    bash -c 'printf "\n" | "$1" --interactive --no-start >/dev/null 2>&1' _ "$ROOT/install.sh"; then
    fail "interactive install with empty selection must fail"
fi

bad_root="$TMP/bad-root"
mkdir -p "$bad_root/etc" "$bad_root/systemd"
if SYSTEMCTL_LOG="$TMP/systemctl-bad.log" \
    PATH="$mockbin:$PATH" \
    HOME_NETOPS_LIB_DIR="$bad_root/lib/home-netops" \
    HOME_NETOPS_ETC_DIR="$bad_root/etc/home-netops" \
    HOME_NETOPS_CONFIG="$bad_root/etc/home-netops/home-netops.conf" \
    HOME_NETOPS_SYSTEMD_DIR="$bad_root/systemd" \
    HOME_NETOPS_SYSTEMCTL="systemctl" \
    HOME_NETOPS_ALLOW_NON_ROOT=1 \
    "$ROOT/install.sh" --services reverse-ssh >/dev/null 2>&1; then
    fail "reverse SSH install without firewall must fail"
fi

mock_get_ip="$TMP/get-ip.sh"
cat > "$mock_get_ip" <<'MOCK'
#!/usr/bin/env bash
echo "203.0.113.7"
MOCK
chmod +x "$mock_get_ip"

mock_tccli="$TMP/tccli"
cat > "$mock_tccli" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TCCLI_LOG"
case "$*" in
    *DescribeFirewallRules*)
        printf '{"FirewallRuleSet":[]}\n'
        ;;
    *CreateFirewallRules*)
        printf '{"RequestId":"ok"}\n'
        ;;
    *)
        printf '{"RequestId":"ok"}\n'
        ;;
esac
MOCK
chmod +x "$mock_tccli"

TCCLI_LOG="$TMP/tccli.log" \
SYSTEMCTL_LOG="$TMP/systemctl-firewall.log" \
PATH="$mockbin:$PATH" \
HOME_NETOPS_CONFIG="$TMP/missing.conf" \
GET_IP_SCRIPT="$mock_get_ip" \
TCCLI_BIN="$mock_tccli" \
TENCENT_INSTANCE_ID="ins-test" \
TENCENT_REGION="ap-test" \
TENCENT_FIREWALL_RULE_DESC="test-rule" \
SYSTEMCTL_BIN="systemctl" \
"$ROOT/firewall/tencent.sh"
grep -q 'DescribeFirewallRules' "$TMP/tccli.log" || fail "Tencent script must describe existing rules"
grep -q 'CreateFirewallRules' "$TMP/tccli.log" || fail "Tencent script must create missing rule"
grep -q '203.0.113.7/32' "$TMP/tccli.log" || fail "Tencent script must use current public IP CIDR"
grep -q 'try-restart home-netops-reverse-ssh.service' "$TMP/systemctl-firewall.log" \
    || fail "Tencent script must restart reverse SSH when firewall changes"

SYSTEMCTL_LOG="$TMP/systemctl-uninstall.log" \
PATH="$mockbin:$PATH" \
HOME_NETOPS_LIB_DIR="$install_root/lib/home-netops" \
HOME_NETOPS_ETC_DIR="$install_root/etc/home-netops" \
HOME_NETOPS_SYSTEMD_DIR="$install_root/systemd" \
HOME_NETOPS_SYSTEMCTL="systemctl" \
HOME_NETOPS_ALLOW_NON_ROOT=1 \
"$ROOT/uninstall.sh" --yes
assert_not_file "$install_root/lib/home-netops"
assert_file "$install_root/etc/home-netops/home-netops.conf"
grep -q 'disable --now home-netops-reverse-ssh.service' "$TMP/systemctl-uninstall.log" \
    || fail "uninstall must stop reverse SSH"

SYSTEMCTL_LOG="$TMP/systemctl-purge.log" \
PATH="$mockbin:$PATH" \
HOME_NETOPS_LIB_DIR="$install_root/lib/home-netops" \
HOME_NETOPS_ETC_DIR="$install_root/etc/home-netops" \
HOME_NETOPS_SYSTEMD_DIR="$install_root/systemd" \
HOME_NETOPS_SYSTEMCTL="systemctl" \
HOME_NETOPS_ALLOW_NON_ROOT=1 \
"$ROOT/uninstall.sh" --purge --yes
assert_not_file "$install_root/etc/home-netops"

echo "PASS"

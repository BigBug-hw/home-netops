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
    aliyun-ddns.sh
    get_public_ip.sh
    home-netops-lib.sh
    install.sh
    reverse-ssh.sh
    start.sh
    stop.sh
    tencent-firewall-service.sh
    tencent_firewall.sh
    uninstall.sh
)

for script in "${scripts[@]}"; do
    bash -n "$ROOT/$script"
done

bash -n "$ROOT/home-netops.conf.example"

grep -q 'Requires=home-netops-tencent-firewall.service' "$ROOT/systemd/home-netops-reverse-ssh.service" \
    || fail "reverse SSH service must require firewall service"
grep -q 'After=.*home-netops-tencent-firewall.service' "$ROOT/systemd/home-netops-reverse-ssh.service" \
    || fail "reverse SSH service must start after firewall service"
grep -q 'ExecStart=/usr/local/lib/home-netops/tencent-firewall-service.sh' "$ROOT/systemd/home-netops-tencent-firewall.service" \
    || fail "firewall service must use restart-aware wrapper"

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
"$ROOT/install.sh" --no-start

assert_file "$install_root/lib/home-netops/aliyun-ddns.sh"
assert_file "$install_root/lib/home-netops/reverse-ssh.sh"
assert_file "$install_root/etc/home-netops/home-netops.conf"
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
"$ROOT/install.sh" --no-start
grep -q '# user change' "$install_root/etc/home-netops/home-netops.conf" || fail "install must not overwrite config"

cat > "$install_root/lib/home-netops/tencent_firewall.sh" <<'MOCK'
#!/usr/bin/env bash
echo "firewall_changed=1"
MOCK
chmod +x "$install_root/lib/home-netops/tencent_firewall.sh"
SYSTEMCTL_LOG="$TMP/systemctl-wrapper.log" \
PATH="$mockbin:$PATH" \
HOME_NETOPS_CONFIG="$install_root/etc/home-netops/home-netops.conf" \
SYSTEMCTL_BIN="systemctl" \
"$install_root/lib/home-netops/tencent-firewall-service.sh"
grep -q 'try-restart home-netops-reverse-ssh.service' "$TMP/systemctl-wrapper.log" \
    || fail "firewall wrapper must restart reverse SSH when firewall changes"

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
HOME_NETOPS_CONFIG="$TMP/missing.conf" \
GET_IP_SCRIPT="$mock_get_ip" \
TCCLI_BIN="$mock_tccli" \
TENCENT_INSTANCE_ID="ins-test" \
TENCENT_REGION="ap-test" \
TENCENT_FIREWALL_RULE_DESC="test-rule" \
"$ROOT/tencent_firewall.sh"
grep -q 'DescribeFirewallRules' "$TMP/tccli.log" || fail "Tencent script must describe existing rules"
grep -q 'CreateFirewallRules' "$TMP/tccli.log" || fail "Tencent script must create missing rule"
grep -q '203.0.113.7/32' "$TMP/tccli.log" || fail "Tencent script must use current public IP CIDR"

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

# home-netops

Personal network automation for a home machine:

- Aliyun DDNS keeps `home.bigbug.ren` pointed at the current public IPv4.
- Tencent Lighthouse firewall keeps one SSH allow rule in sync with the current public IPv4.
- Reverse SSH exposes the home SSH service through the cloud host after the firewall rule is ready.
- Proxy server exposes SOCKS5 and HTTP proxy listeners on the EasyTier LAN.

## Layout

```text
ddns/                 Aliyun DDNS update
firewall/             Tencent Lighthouse firewall sync
lib/                  Shared shell helpers, public IPv4 detection, reverse SSH, and proxy tools
install.sh            Install scripts, config example, and systemd units
uninstall.sh          Stop services and remove installed files
systemd/              systemd service and timer units
config/               Example config and EasyTier configs
tests/run.sh          Offline regression checks with command mocks
```

The installed script root is `/usr/local/lib/home-netops`. Runtime config lives at `/etc/home-netops/home-netops.conf`.

## Dependencies

Install the tools used by the enabled features:

```bash
sudo apt install autossh curl jq iproute2
```

Aliyun DDNS needs the Aliyun CLI configured with the profile in `ALIYUN_PROFILE`.

```bash
# Install and configure aliyun CLI according to Aliyun's current docs.
aliyun configure --profile ddns
```

Tencent firewall sync needs `tccli`. The default config expects it in the project venv under `/usr/local/lib/home-netops/.venv/bin/tccli`.

```bash
cd /usr/local/lib/home-netops
uv venv
uv pip install tccli
tccli auth login --browser no
```

Proxy server needs EasyTier and `gost`. Install EasyTier as `easytier.service` first, then install `gost` somewhere stable and set `GOST_BIN` in `home-netops.conf`.

Example `gost` install:

```bash
mkdir -p /home/bigbug/software/gost
cd /home/bigbug/software/gost
wget https://github.com/go-gost/gost/releases/download/v3.2.7-nightly.20260426/gost_3.2.7-nightly.20260426_linux_amd64v3.tar.gz
tar zxvf gost_3.2.7-nightly.20260426_linux_amd64v3.tar.gz
```

## Install

```bash
sudo ./install.sh --services all
```

This copies scripts into `/usr/local/lib/home-netops`, creates `/etc/home-netops/home-netops.conf` if missing, installs systemd units, reloads systemd, and enables:

- `home-netops-aliyun-ddns.timer`
- `home-netops-tencent-firewall.timer`
- `home-netops-reverse-ssh.service`
- `home-netops-proxy-server.service`

Install without starting services:

```bash
sudo ./install.sh --services all --no-start
```

Install only selected services:

```bash
sudo ./install.sh --services ddns
sudo ./install.sh --services firewall
sudo ./install.sh --services firewall,reverse-ssh
sudo ./install.sh --services server
```

Interactive install:

```bash
sudo ./install.sh --interactive
```

The interactive prompt has no default; pressing Enter without a service name fails.

Available service names:

- `ddns`: installs `home-netops-aliyun-ddns.service` and `.timer`.
- `firewall`: installs `home-netops-tencent-firewall.service` and `.timer`.
- `reverse-ssh`: installs `home-netops-reverse-ssh.service`; it requires `firewall`.
- `server`: installs `home-netops-proxy-server.service`; it requires an existing `easytier.service`.
- `all`: installs everything, but it must still be specified explicitly.

Edit config before the first real run:

```bash
sudoedit /etc/home-netops/home-netops.conf
```

## Manual Commands

Run one DDNS update:

```bash
sudo /usr/local/lib/home-netops/ddns/aliyun.sh
```

Sync the Tencent firewall rule:

```bash
sudo /usr/local/lib/home-netops/firewall/tencent.sh
```

Control the reverse SSH tunnel:

```bash
sudo systemctl start home-netops-reverse-ssh.service
sudo systemctl stop home-netops-reverse-ssh.service
sudo journalctl -u home-netops-reverse-ssh.service -f
```

Run the configured reverse SSH command directly:

```bash
sudo /usr/local/lib/home-netops/lib/reverse-ssh.sh
```

Run the configured proxy server directly:

```bash
sudo /usr/local/lib/home-netops/lib/proxy-server.sh
```

## Configuration

Start from `config/home-netops.conf.example`. Important fields:

- `PUBLIC_IP_URLS`, `PUBLIC_IP_TIMEOUT`: public IPv4 probes.
- `PUBLIC_IP_NO_PROXY`: defaults to `1`, so public IPv4 detection bypasses proxy environment variables and returns the local network egress IP instead of the proxy server IP.
- `ALIYUN_*`: DNS profile, domain, RR, record type, line, and TTL.
- `TENCENT_*`: Lighthouse instance, region, protocol, port, action, and rule description.
- `RESTART_REVERSE_AFTER_FIREWALL_CHANGE`: restart reverse SSH when the firewall IP changes.
- `CLOUD_HOST`, `CLOUD_USER`, `CLOUD_PORT`: cloud host IP/user/SSH port used by `home-netops-reverse-ssh.service`.
- `REMOTE_BIND_*`, `LOCAL_TARGET_*`: reverse SSH forwarding settings.
- `IDENTITY_FILE`: optional SSH private key path.
- `CHECK_LOCAL_SSHD`: set to `0` to skip the local SSH port check.
- `EASYTIER_LAN_IP`: EasyTier LAN IP to bind the proxy server on, for example `10.144.144.3`.
- `GOST_BIN`: path to `gost`.
- `PROXY_SOCKS_PORT`, `PROXY_HTTP_PORT`: SOCKS5 and HTTP proxy listen ports.

## Proxy Client

Point clients at the EasyTier LAN IP configured on the proxy server:

```bashrc
export ALL_PROXY=socks5://10.144.144.3:1080
export all_proxy=socks5://10.144.144.3:1080
export HTTP_PROXY=http://10.144.144.3:8080
export HTTPS_PROXY=http://10.144.144.3:8080
export http_proxy=http://10.144.144.3:8080
export https_proxy=http://10.144.144.3:8080
```

## Uninstall

Keep config:

```bash
sudo ./uninstall.sh --yes
```

Remove config too:

```bash
sudo ./uninstall.sh --purge --yes
```

## Test

The test suite is offline and uses mocks for `systemctl` and cloud CLIs.

```bash
tests/run.sh
```

## EasyTier Notes

EasyTier configs are kept under `config/` for manual use.

Example:

```bash
./easytier-linux-x86_64/easytier-core --config-file config/easytier-home.yaml
```

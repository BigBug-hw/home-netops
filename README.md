# home-netops

Personal network automation for a home machine:

- Aliyun DDNS keeps `home.bigbug.ren` pointed at the current public IPv4.
- Tencent Lighthouse firewall keeps one SSH allow rule in sync with the current public IPv4.
- Reverse SSH exposes the home SSH service through the cloud host after the firewall rule is ready.

## Layout

```text
ddns/                 Aliyun DDNS update
firewall/             Tencent Lighthouse firewall sync
lib/                  Shared shell helpers and public IPv4 detection
reverse-ssh.sh        autossh reverse tunnel entrypoint
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

## Install

```bash
sudo ./install.sh
```

This copies scripts into `/usr/local/lib/home-netops`, creates `/etc/home-netops/home-netops.conf` if missing, installs systemd units, reloads systemd, and enables:

- `home-netops-aliyun-ddns.timer`
- `home-netops-tencent-firewall.timer`
- `home-netops-reverse-ssh.service`

Install without starting services:

```bash
sudo ./install.sh --no-start
```

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

## Configuration

Start from `config/home-netops.conf.example`. Important fields:

- `PUBLIC_IP_URLS`, `PUBLIC_IP_TIMEOUT`: public IPv4 probes.
- `ALIYUN_*`: DNS profile, domain, RR, record type, line, and TTL.
- `TENCENT_*`: Lighthouse instance, region, protocol, port, action, and rule description.
- `RESTART_REVERSE_AFTER_FIREWALL_CHANGE`: restart reverse SSH when the firewall IP changes.
- `CLOUD_*`, `REMOTE_BIND_*`, `LOCAL_TARGET_*`: reverse SSH endpoint and forwarding settings.
- `IDENTITY_FILE`: optional SSH private key path.
- `CHECK_LOCAL_SSHD`: set to `0` to skip the local SSH port check.

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

# home-netops

Personal network automation for three roles:

- `home`: Aliyun DDNS, Tencent firewall sync, reverse SSH, and EasyTier.
- `ali`: EasyTier and a SOCKS5/HTTP proxy server on the EasyTier LAN.
- `tencent`: EasyTier only.

The repository directory is the application directory. Installation does not copy scripts or config into `/usr/local` or `/etc`; it only installs the selected role's systemd units.

## Layout

```text
check.sh              Read-only dependency, config, and systemd status checks
config/               JSON role config and EasyTier configs
ddns/                 Aliyun DDNS update
firewall/             Tencent Lighthouse firewall sync
install.sh            Role-driven systemd unit installer
lib/                  Shared helpers and service entrypoints
tests/run.sh          Offline regression checks with command mocks
uninstall.sh          Remove generated home-netops systemd units
```

## Dependencies

Base tools:

```bash
sudo apt install curl jq
```

Install the tools used by the enabled role:

- `home`: `aliyun`, `uv`, `tccli`, `autossh`, `easytier-core`, and `iproute2` for the optional local SSH port check.
- `ali`: `easytier-core` and `gost`.
- `tencent`: `easytier-core`.

Aliyun DDNS needs the Aliyun CLI profile configured with `ALIYUN_PROFILE`.

```bash
aliyun configure --profile ddns
```

Tencent firewall sync uses `TCCLI_BIN`, which defaults to `.venv/bin/tccli` under `HOME_NETOPS_APP_HOME`. If that file does not exist, `firewall/tencent.sh` installs it with `uv`:

```bash
uv venv && uv pip install tccli
```

Then authenticate `tccli` for the configured Lighthouse instance:

```bash
./.venv/bin/tccli auth login --browser no
```

## Configuration

Edit `config/home-netops.json`.

```json
{
  "shared": {
    "PUBLIC_IP_TIMEOUT": "8"
  },
  "services": {
    "easytier": {
      "EASYTIER_BIN": "easytier-core"
    },
    "proxy-server": {
      "GOST_BIN": "gost",
      "PROXY_SOCKS_PORT": "1080",
      "PROXY_HTTP_PORT": "8080"
    },
    "proxy-client": {
      "PROXY_SERVER_IP": "10.144.144.3",
      "PROXY_SOCKS_PORT": "1080",
      "PROXY_HTTP_PORT": "8080"
    }
  },
  "roles": {
    "ali": {
      "services": ["easytier", "proxy-server"],
      "overrides": {
        "easytier": {
          "EASYTIER_CONFIG": "config/easytier-ali.yaml"
        }
      }
    }
  }
}
```

`shared` applies to every role. `services.<service>` groups default variables by service. `roles.<role>.overrides.<service>` overrides one service for one role. Explicit environment variables override JSON values at runtime.

Supported services:

- `ddns`: Aliyun DNS A record update.
- `firewall`: Tencent Lighthouse firewall rule sync.
- `reverse-ssh`: reverse SSH tunnel; requires `firewall`.
- `easytier`: EasyTier node.
- `proxy-server`: SOCKS5/HTTP proxy server; requires `easytier`.
- `proxy-client`: writes shell proxy exports that point at the proxy server.

Relative paths in JSON, such as `config/easytier-ali.yaml`, are resolved from `HOME_NETOPS_APP_HOME`, which the installer sets to the repository path.

## Install

Install the current repository for a role:

```bash
sudo ./install.sh --role home --config ./config/home-netops.json
sudo ./install.sh --role ali --config ./config/home-netops.json
sudo ./install.sh --role tencent --config ./config/home-netops.json
```

Install units without enabling or starting them:

```bash
sudo ./install.sh --role home --config ./config/home-netops.json --no-start
```

Install from a different application directory:

```bash
sudo ./install.sh --role ali --config /opt/home-netops/config/home-netops.json --app-home /opt/home-netops
```

The old interactive and `--services` installation modes are intentionally removed. The role config is the only source of enabled services.

## Check

Run a read-only check after editing config or installing units:

```bash
./check.sh --role home --config ./config/home-netops.json
```

The check validates JSON structure, service dependencies, required commands, important config values, EasyTier config paths, and systemd unit status.

## Manual Commands

Run a service entrypoint directly by setting the role, config, and app home:

```bash
export HOME_NETOPS_ROLE=home
export HOME_NETOPS_CONFIG="$PWD/config/home-netops.json"
export HOME_NETOPS_APP_HOME="$PWD"

sudo -E ./ddns/aliyun.sh
sudo -E ./firewall/tencent.sh
sudo -E ./lib/reverse-ssh.sh
sudo -E ./lib/easytier.sh
sudo -E ./lib/proxy-server.sh
```

Control installed systemd units:

```bash
sudo systemctl status home-netops-easytier.service
sudo journalctl -u home-netops-easytier.service -f
```

## Proxy Client

Enable `proxy-client` in a role to manage proxy exports in the invoking user's `~/.bashrc`. Under `sudo`, the target is `SUDO_USER`'s `~/.bashrc`; without `sudo`, it is the current user's `~/.bashrc`.

Example role:

```json
{
  "roles": {
    "client": {
      "services": ["proxy-client"],
      "overrides": {}
    }
  }
}
```

The installer writes a managed block with these variables:

```bashrc
export ALL_PROXY=socks5://10.144.144.3:1080
export all_proxy=socks5://10.144.144.3:1080
export HTTP_PROXY=http://10.144.144.3:8080
export HTTPS_PROXY=http://10.144.144.3:8080
export http_proxy=http://10.144.144.3:8080
export https_proxy=http://10.144.144.3:8080
```

`PROXY_SERVER_IP` is the proxy server's EasyTier IP. `uninstall.sh` removes only the home-netops managed block and leaves other `.bashrc` content unchanged.

## EasyTier Secret Rotation

The committed EasyTier config files are templates. Keep real node configs in ignored local files or on the deployed hosts.

Create a host map from the example:

```bash
cp config/deploy-hosts.example.json config/deploy-hosts.json
```

Edit `config/deploy-hosts.json` with the SSH endpoint, app directory, and EasyTier config path for each role.

Generate a new network secret and X25519 keypair for every role without touching remote hosts:

```bash
tools/rotate-easytier-secrets.sh --dry-run --output-dir /tmp/home-netops-rotate
```

Apply the rotation over SSH:

```bash
tools/rotate-easytier-secrets.sh --apply --hosts config/deploy-hosts.json
```

The apply flow uploads each rendered config as a staged file, installs it with mode `0600`, atomically replaces the active config, restarts `tencent`, then `ali`, then `home`, and rolls back from the remote backup if a restart fails.

## Uninstall

Remove generated home-netops systemd units and the proxy-client `.bashrc` block:

```bash
sudo ./uninstall.sh --yes
```

This does not remove the repository, JSON config, or EasyTier configs.

## Test

The test suite is offline and uses mocks for `systemctl` and cloud CLIs.

```bash
tests/run.sh
```

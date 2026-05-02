# home-netops

个人网络运维脚本，用 systemd 管理 DDNS、EasyTier 组网、云防火墙同步、反向 SSH 和代理。

## 当前效果

- `home`：更新阿里云 DNS A 记录，同步腾讯云 Lighthouse 防火墙，启动 EasyTier，并在 WSL 本机提供 HTTP 代理给 Windows 使用。
- `ali`：启动 EasyTier，并在 EasyTier 网络内提供 SOCKS5/HTTP 代理。
- `tencent`：启动 EasyTier 节点。

服务由 `config/home-netops.json` 里的 `roles.<role>.services` 决定；安装脚本不会再用交互方式选择服务。

## 准备

基础依赖：

```bash
sudo apt install curl jq
```

按启用的服务安装对应工具：

- `ddns`：`aliyun`
- `firewall`：`uv`、`tccli`
- `reverse-ssh`：`autossh`
- `easytier`：`easytier-core`
- `proxy-server`：`gost`
- `proxy-client`：`gost`

阿里云 DDNS 使用 `ddns` profile：

```bash
/bin/bash -c "$(curl -fsSL https://aliyuncli.alicdn.com/install.sh)"

aliyun configure set \
  --profile ddns \
  --mode AK \
  --region cn-beijing \
  --access-key-id "Your AccessKeyId" \
  --access-key-secret "Your AccessKeySecret"
```

腾讯云防火墙默认使用仓库目录下 `.venv/bin/tccli`。如果文件不存在，脚本会用 `uv` 安装；首次使用前需要登录：

```bash
uv venv
uv pip install tccli
./.venv/bin/tccli auth login --browser no
```

## 配置

编辑：

```bash
config/home-netops.json
```

配置层级：

- `shared`：所有角色共用。
- `services.<service>`：某个服务的默认变量。
- `roles.<role>.overrides.<service>`：某个角色对某个服务的覆盖值。

EasyTier 运行时配置使用被 Git 忽略的本地文件，例如：

```bash
config/easytier-home.local.yaml
config/easytier-ali.local.yaml
config/easytier-tencent.local.yaml
```

仓库里的 `config/easytier-*.yaml` 只当模板使用。

## 安装

在对应机器上安装对应角色：

```bash
sudo ./install.sh --role home --config ./config/home-netops.json
sudo ./install.sh --role ali --config ./config/home-netops.json
sudo ./install.sh --role tencent --config ./config/home-netops.json
```

只写入 systemd unit，不启用也不启动：

```bash
sudo ./install.sh --role home --config ./config/home-netops.json --no-start
```

仓库目录不在当前路径时指定 `--app-home`：

```bash
sudo ./install.sh \
  --role ali \
  --config /opt/home-netops/config/home-netops.json \
  --app-home /opt/home-netops
```

## 检查和运维

安装后检查角色状态：

```bash
./check.sh --role home --config ./config/home-netops.json
```

查看 systemd 状态和日志：

```bash
sudo systemctl status home-netops-easytier.service
sudo journalctl -u home-netops-easytier.service -f
```

常用 unit：

- `home-netops-aliyun-ddns.timer`
- `home-netops-tencent-firewall.timer`
- `home-netops-reverse-ssh.service`
- `home-netops-easytier.service`
- `home-netops-proxy-server.service`
- `home-netops-proxy-client.service`

## 代理客户端

启用 `proxy-client` 的角色会启动本机 HTTP 转发：

```bash
gost -L http://127.0.0.1:8080 -F socks5://10.144.144.3:1080
```

效果是把 EasyTier 内网里的 SOCKS5 代理转成 WSL 本机的 HTTP 代理。Windows 侧可使用：

```bash
http://127.0.0.1:8080
```

安装时也会把调用用户的 `~/.bashrc` 指向这个本机代理：

```bash
export ALL_PROXY=http://127.0.0.1:8080
export all_proxy=http://127.0.0.1:8080
export HTTP_PROXY=http://127.0.0.1:8080
export HTTPS_PROXY=http://127.0.0.1:8080
export http_proxy=http://127.0.0.1:8080
export https_proxy=http://127.0.0.1:8080
```

在 `sudo` 下安装时，目标是 `SUDO_USER` 的 `~/.bashrc`；不用 `sudo` 时，目标是当前用户的 `~/.bashrc`。

脚本只管理 `# home-netops proxy-client start` 和 `# home-netops proxy-client end` 之间的块，不会改动其它内容。

## EasyTier 密钥轮换

先复制并填写主机映射：

```bash
cp config/deploy-hosts.example.json config/deploy-hosts.json
```

本地生成新配置，不上传：

```bash
tools/rotate-easytier-secrets.sh --dry-run --output-dir /tmp/home-netops-rotate
```

上传并重启远端 EasyTier：

```bash
tools/rotate-easytier-secrets.sh --apply --hosts config/deploy-hosts.json
```

注意：`deploy-hosts.json` 里的 `easytier_config` 应指向 `.local.yaml` 运行时文件。应用轮换时会按 `tencent -> ali -> home` 的顺序重启，失败会尝试恢复远端备份。

## 卸载

移除 home-netops 生成的 systemd unit 和代理客户端 `.bashrc` 托管块：

```bash
sudo ./uninstall.sh --yes
```

卸载不会删除仓库、JSON 配置或 EasyTier 配置文件。

## 注意事项

- `install.sh` 和 `uninstall.sh` 默认需要 root。
- `reverse-ssh` 必须和 `firewall` 在同一个角色里启用。
- `proxy-server` 必须和 `easytier` 在同一个角色里启用。
- `proxy-client` 默认只监听 `127.0.0.1:8080`，不暴露到局域网。
- 修改配置或安装后，优先跑 `check.sh` 再看服务日志。
- 离线测试入口是：

```bash
tests/run.sh
```

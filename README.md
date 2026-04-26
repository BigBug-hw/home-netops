# home-netops

## ddns

安装`aliyun`, 参考: <https://help.aliyun.com/zh/cli/?spm=a2c4g.11186623.0.0.43e2668bNUnuhx>

## firewall

```bash
cd /usr/local/lib/home-netops
uv venv
uv pip install tccli
tccli auth login --browser no
```

## easytier

### 安装

参考: <https://easytier.cn/>

安装到`/home/bigbug/software/easytier`

### tencent

1. 启动web server(可选)

    ```bash
    ./easytier-web-embed --api-server-port 11211 --api-host "http://127.0.0.1:11211" --config-server-port 22020 --config-server-protocol udp
    ```

2. 启动共享节点:

    ```bash
    ./easytier-linux-x86_64/easytier-core --config-file ./easytier-tencent.yaml
    ```

    可以指定`--config-server udp://127.0.0.1:22020/admin`通过web管理设备

3. 安装到系统服务

```bash
sudo ./easytier-linux-x86_64/easytier-cli service install \
    --description "easytier" \
    --display-name "easytier" \
    --disable-autostart \
    --core-path /home/bigbug/software/easytier/easytier-linux-x86_64/easytier-core \
    --service-work-dir /home/bigbug/software/easytier \
    -- --config-file /home/bigbug/software/easytier/easytier-ali.toml
```

### home

```bash
./easytier-linux-x86_64/easytier-core --config-file ./easytier-home.yaml
```

```bash
sudo ./easytier-linux-x86_64/easytier-cli service install \
    --description "easytier" \
    --display-name "easytier" \
    --disable-autostart \
    --core-path /home/renyq/software/easytier/easytier-linux-x86_64/easytier-core \
    --service-work-dir /home/renyq/software/easytier \
    -- --config-file /home/renyq/software/easytier/easytier-home.toml
```

### ali

```bash
./easytier-linux-x86_64/easytier-core --config-file ./easytier-ali.yaml
```

```bash
sudo ./easytier-linux-x86_64/easytier-cli service install \
    --description "easytier" \
    --display-name "easytier" \
    --disable-autostart \
    --core-path /home/bigbug/software/easytier/easytier-linux-x86_64/easytier-core \
    --service-work-dir /home/bigbug/software/easytier \
    -- --config-file /home/bigbug/software/easytier/easytier-ali.toml
```

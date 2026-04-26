# home-netops

## easytier

### 安装

参考: <https://easytier.cn/>

### tencent

1. 启动web server:

    ```bash
    ./easytier-web-embed --api-server-port 11211 --api-host "http://127.0.0.1:11211" --config-server-port 22020 --config-server-protocol udp
    ```

2. 启动共享节点:

    ```bash
    ./easytier-linux-x86_64/easytier-core --config-file ./easytier-tencent.yaml --config-server udp://127.0.0.1:22020/admin
    ```

### home

```bash
./easytier-linux-x86_64/easytier-core --config-file ./easytier-home.yaml
```

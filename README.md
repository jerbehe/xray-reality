# xray-reality（reality.sh 的 Docker 化版本）

由 Xray VLESS + REALITY 一键安装脚本改造的服务镜像：构建时装好 Xray 二进制，
首次启动时自动生成 UUID / X25519 密钥并写配置，前台运行 xray（PID 1）。
附带订阅服务 `sub.sh`，可把全部节点整合成一个订阅地址供客户端订阅（见下）。

## 构建与运行

```bash
docker build -t xray-reality .
docker run -d --name xray-reality --restart unless-stopped \
  -p 443:443 \
  -v xray-data:/usr/local/etc/xray \
  xray-reality
docker logs xray-reality        # 查看客户端链接
```

或直接使用 docker compose：

```bash
docker compose up -d
docker compose logs xray-reality
```

## 环境变量（均可选）

| 变量 | 默认 | 说明 |
|---|---|---|
| `XRAY_PORT` | `443` | 监听端口 |
| `XRAY_SNI` | `www.amazon.com` | 伪装域名（dest） |
| `XRAY_SHORT_ID` | `88` | shortId（十六进制） |
| `XRAY_UUID` | 自动生成 | 指定客户端 UUID |
| `XRAY_PRIVATE_KEY` | 自动生成 | REALITY 私钥；单独填写时公钥自动推导 |
| `XRAY_PUBLIC_KEY` | 与私钥配对 | 与私钥配套的公钥 |
| `SERVER_IP` | 自动探测 | 对外公网 IP，仅用于客户端链接显示 |

## 出口代理（可选）

设置 `OUTBOUND_PROXY` 后，客户端流量经该代理出网，容器对外呈现的就是代理的出口 IP；
不设置时流量由本机直接出网（行为与之前完全一致）。

```bash
docker run -d --name xray-reality -p 443:443 \
  -e OUTBOUND_PROXY=socks5://192.168.2.2:20001 \
  -v xray-data:/usr/local/etc/xray xray-reality
```

支持 `socks5://`、`http://`、`https://`，可带 `user:pass@`（特殊字符按 URL 编码，`%40` = `@`）。
未设置 `OUTBOUND_PROXY` 时依次回退读取 `ALL_PROXY` / `all_proxy` / `HTTPS_PROXY` / `HTTP_PROXY`，
`NO_PROXY_ENV=1` 可关闭这种回退。

| 变量 | 默认 | 说明 |
|---|---|---|
| `OUTBOUND_PROXY` | 空 | 出口代理地址，空 = 本机直连出网 |
| `UDP_POLICY` | `block-quic` | `block-quic` 阻断 UDP/443 让客户端回退 TCP；`proxy` 全部 UDP 走代理（需代理支持 UDP ASSOCIATE）；`direct` UDP 本机直连；`block` 全部阻断 |
| `PROXY_BYPASS` | 空 | 绕过代理直连的目标，逗号分隔，支持 `geosite:cn`、`geoip:cn`、`example.com`、`192.168.0.0/16` |
| `NO_PROXY_ENV` | 空 | 设为 `1` 时忽略 `ALL_PROXY` 等标准变量 |

行为要点：

- 启动时经代理探测一次出口 IP 并打印（`出口 IP : x.x.x.x`），失败只告警不阻止启动；
  客户端链接里的地址仍是本机公网 IP（入口 IP 探测强制不走代理）。
- 代理地址写错（缺端口、协议不支持等）会**直接终止启动**，避免流量以本机 IP 裸奔。
- 私网地址（`geoip:private`）始终直连，不会发给代理。
- REALITY 握手向伪装域名（`dest`）的连接不经过代理，由容器直接发出，代理无需能访问该域名。

一机多出口 IP 有两种玩法：

1. **一容器多线路（推荐）**：用多实例清单（见下节），一个 xray 进程承载多个
   REALITY 入站/多用户，每条线路绑定不同 `OUTBOUND_PROXY`，内存开销约为多容器方案的 1/10。
2. **一容器一线路**：起多个容器，各自用不同的 `OUTBOUND_PROXY` 与不同的对外端口；
   代理跑在宿主机上时加 `--add-host=host.docker.internal:host-gateway`，
   地址写 `socks5://host.docker.internal:<端口>`。

## 多实例清单（一端口多用户 / 一端口一实例）

容器按以下顺序查找 `instances.json`，找到即进入多实例模式（单个 xray 进程同时承载
多个 REALITY 入站）：

1. `-e XRAY_INSTANCES=/path/instances.json` 显式指定
2. `/etc/xray-reality/instances.json`（系统默认路径，推荐把宿主机目录挂进来：
   `-v /etc/xray-reality:/etc/xray-reality:ro`）
3. 配置卷中的 `instances.json`（旧版兼容）

`proxy` 支持继承——user 未指定时继承入站级 `proxy`；无 `users` 数组等价于单个匿名用户。

```json
[
  {
    "name": "main", "port": 443,
    "address": "sg.example.com",
    "users": [
      { "name": "alice", "proxy": "socks5://192.168.2.2:20001" },
      { "name": "bob",   "proxy": "socks5://192.168.2.2:20002" },
      { "name": "carol" }
    ]
  },
  {
    "name": "jp", "port": 8443, "sni": "www.cloudflare.com",
    "proxy": "socks5://192.168.2.2:20003"
  }
]
```

- 同一入站端口上的每个用户通过各自 UUID 区分，流量按身份分流到各自的 `proxy`
  （无 `proxy` 的用户本机直连出网）——即“一个入口端口、多个出口 IP”。
- `address` 自定义节点连接地址（域名或 IP），用户级 > 入站级 > `SERVER_IP` > 自动探测；
  全部线路都显式指定时跳过公网 IP 探测，适合每条线路有自己 DDNS 域名的部署。
- 每实例密钥与每用户 UUID 持久化到 `meta/<实例名>.env`，容器重建不变号；
  删除对应文件即重新生成该实例身份。
- 启动时对每个实例做 **REALITY 握手自检**（回环起临时客户端/服务端实测握手）。
  部分站点（实测 www.microsoft.com）不能用作伪装目标，失败会显式告警，
  可设 `XRAY_SELFTEST=0` 跳过。
- 端口重复、代理地址非法、`udp_policy` 非法等错误会直接拒绝启动。
- 多端口部署建议 `network_mode: host`；bridge 模式需把清单里的端口段都发布出去。

| 变量 | 默认 | 说明 |
|---|---|---|
| `XRAY_INSTANCES` | `<配置卷>/instances.json` | 清单路径，文件存在即启用多实例模式 |
| `XRAY_SELFTEST` | `1` | 设为 `0` 跳过启动时的 REALITY 握手自检 |

## 订阅服务（把全部节点整合成一个订阅地址）

除了逐个复制链接，镜像还带一个订阅服务 `sub.sh`：它读取配置卷里由 entrypoint 写出的
`nodes.json`（含全部实例/用户的地址、端口、UUID、公钥、shortId），生成标准订阅内容并用
HTTP 提供，客户端填一个地址即可自动更新全部节点。

提供四种格式：

| 路径 | 内容 | 适用 |
|---|---|---|
| `/sub.txt` | base64 编码的 vless 链接 | v2rayN / NekoBox / Shadowrocket / Clash Verge 等通用 |
| `/plain.txt` | 明文链接，一行一条 | 手动复制、其它工具导入 |
| `/clash.yaml` | `proxies:` 列表 | Clash / mihomo |
| `/nodes.json` | 结构化节点信息 | 自建脚本 |

### 用法

订阅服务**与 xray 在同一个容器内运行**，默认就是开启的：entrypoint 在启动 xray 前后台
拉起它，节点清单更新后由它自动重新生成。只要把容器端口发布出来就能用：

```bash
docker run -d --name xray-reality --restart unless-stopped \
  -p 443:443 -p 127.0.0.1:8080:8080 \
  -v xray-data:/usr/local/etc/xray \
  xray-reality

docker logs xray-reality              # 启动日志里打印订阅地址
curl -s http://127.0.0.1:8080/sub.txt | base64 -d
```

用 `docker compose up -d` 时，compose 文件里已经把 `127.0.0.1:8080` 发布出来了，
`docker compose logs xray-reality` 即可看到订阅地址。

不需要订阅服务就设 `SUB_PORT=0`（完全不启动，行为与加订阅之前一致）；
容器健康检查在订阅服务开启时会一并检查它的 HTTP 端口。

### 环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `SUB_PORT` | `8080` | 订阅服务监听端口；设为 `0` 关闭订阅服务 |
| `SUB_ADDR` | `0.0.0.0` | 监听地址（容器内网地址，不发布端口就不会暴露到公网） |
| `SUB_TOKEN` | 空 | 设置后订阅地址变为 `/<token>/sub.txt`，**强烈建议设置** |
| `SUB_REFRESH` | `60` | 每隔多少秒按最新 `nodes.json` 重新生成；`0` = 只在启动时生成一次 |
| `SUB_BASE_URL` | 空 | 对外访问前缀如 `https://sub.example.com`，仅影响日志里打印的地址 |
| `SUB_DIR` | `/var/lib/xray-sub` | 订阅文件输出目录 |

> 如果想把订阅单独放到另一个容器（只读挂载同一配置卷），也可以
> `docker run -v xray-data:/usr/local/etc/xray:ro -p 127.0.0.1:8080:8080 xray-reality /sub.sh serve`；
> 但默认用法是同容器，无需额外容器。

### 安全提示

- **订阅内容等于节点凭据**（含 UUID 与 REALITY 公钥），拿到订阅地址就能连你的节点。
  请设置 `SUB_TOKEN`，并优先只监听 `127.0.0.1`、由 nginx / Caddy 套一层 HTTPS 再对外：

  ```nginx
  location /sub/ {
      proxy_pass http://127.0.0.1:8080/;   # 末尾的 / 会去掉 /sub/ 前缀
  }
  ```

  此时把 `SUB_BASE_URL` 设为对外地址，日志里打印的就是可直接复制的公网地址。
- 服务端已用 `--no-listing` 禁止列目录，根目录不会泄露令牌子目录的名字。
- 订阅服务本身不发任何外网请求，只读取配置卷里的 `nodes.json`。

## 获取节点链接

容器每次启动都会把 vless 链接打印到日志；也可以用仓库里的辅助脚本随时生成：

```bash
docker logs xray-reality        # 方式一：直接看启动日志（多实例模式打印全部线路）
./show-link.sh                  # 方式二：多实例模式列出全部链接；单实例输出单条
./show-link.sh my-container 1.2.3.4   # 指定容器名和公网 IP
```

链接格式说明（各参数来自配置卷中的 meta.env）：

```
vless://<UUID>@<公网IP>:<端口>?encryption=none&flow=xtls-rprx-vision
        &security=reality&sni=<SNI>&fp=chrome&pbk=<公钥>&sid=<shortId>&type=tcp&headerType=none#<节点名>
```

注意：如果用了 `-p 8443:443` 之类的端口映射，链接里的端口应写成宿主机侧端口；
公网 IP 变化后重新执行 `show-link.sh` 即可，服务端无需任何改动。

## 身份持久化

把 `/usr/local/etc/xray` 挂载为卷即可。单实例模式生成 `meta.env`（身份参数）、
`config.json`（服务端配置）、`client.json`（客户端参数）；多实例模式生成
`instances.resolved.json`（含密钥/UUID 的最终清单）与 `meta/<实例名>.env`。
两种模式都会额外生成 `nodes.json`（全部节点的地址/端口/UUID/公钥/shortId/链接），
订阅服务 `sub.sh` 读它生成订阅，自建脚本也可用它取节点信息。
容器重建后复用同一身份；想重新生成：删除对应文件或清空该卷。

## 镜像涉及的网络请求

- 构建期：Alpine apk 软件源；`github.com/XTLS/Xray-core` Releases（下载二进制）
- 运行期：未设置 `SERVER_IP` 时访问公网 IP 探测接口
  （cloudflare.com/cdn-cgi/trace、ipv4.icanhazip.com、ipinfo.io/ip、api.ipify.org、checkip.amazonaws.com）；
  设置了出口代理时，额外经代理请求一次 cloudflare.com/cdn-cgi/trace 用于打印出口 IP

## 与原脚本的差异

- 无 systemd：由 entrypoint 前台运行 xray，信号直达进程
- 密钥在运行期生成，不烧进镜像层（避免镜像分发导致私钥泄露）
- 交互式输入（端口/SNI）改为环境变量
- 配置文件权限 600（原脚本为 644，私钥对本机所有用户可读）
- 移除原脚本的清理逻辑（`rm -f reality.sh` 等相对路径删除）

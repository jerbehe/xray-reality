#!/bin/sh
# 订阅服务：把配置卷里的全部节点整合成一个订阅，供客户端直接订阅
#
# 两种用法：
#   1) 独立服务（推荐）：docker compose 里的 xray-reality-sub 服务，或
#        docker run -d --name xray-reality-sub -v xray-data:/usr/local/etc/xray:ro \
#          -p 127.0.0.1:8080:8080 xray-reality /sub.sh serve
#      独立容器与 xray 互不影响，可单独重启、单独加反向代理。
#   2) 随 xray 容器一起跑：给 xray 容器设置 SUB_PORT=8080，entrypoint 后台拉起本脚本。
#
# 子命令（默认 gen）：
#   gen     按当前 nodes.json 生成一次订阅文件
#   serve   等节点清单就绪后生成并提供 HTTP 订阅（前台运行，作为容器主进程）
#
# 生成的文件（SUB_DIR 下；设置 SUB_TOKEN 时在 SUB_DIR/<token>/ 下）：
#   sub.txt      base64 编码的 vless 链接，v2rayN / NekoBox / Shadowrocket / Clash Verge 通用
#   plain.txt    明文链接，一行一个
#   clash.yaml   Clash / mihomo 的 proxies 列表
#   nodes.json   结构化节点信息（供脚本消费）
#   index.html   人类可读的节点清单页
#
# 环境变量：
#   XRAY_CONF_DIR  配置卷路径，默认 /usr/local/etc/xray（读其中的 nodes.json）
#   SUB_DIR        订阅文件输出目录，默认 /var/lib/xray-sub
#   SUB_PORT       监听端口，默认 8080
#   SUB_ADDR       监听地址，默认 0.0.0.0（容器内网地址，不发布就不会暴露到公网）
#   SUB_TOKEN      订阅令牌，非空时订阅地址变为 /<token>/sub.txt（推荐设置）
#   SUB_REFRESH    重新生成间隔（秒），默认 60；0 = 只在启动时生成一次
#   SUB_BASE_URL   对外访问前缀，如 https://sub.example.com，仅影响日志里打印的地址
set -eu

CONF_DIR="${XRAY_CONF_DIR:-/usr/local/etc/xray}"
NODES="$CONF_DIR/nodes.json"
SUB_DIR="${SUB_DIR:-/var/lib/xray-sub}"
SUB_PORT="${SUB_PORT:-8080}"
SUB_ADDR="${SUB_ADDR:-0.0.0.0}"
SUB_TOKEN="${SUB_TOKEN:-}"
SUB_REFRESH="${SUB_REFRESH:-60}"
SUB_BASE_URL="${SUB_BASE_URL:-}"

log() { printf '[sub] %s\n' "$*"; }
die() {
    printf '[sub] 错误: %s\n' "$*" >&2
    exit 1
}

command -v jq >/dev/null 2>&1 || die "缺少 jq"

# 令牌会作为 URL 路径，必须是单层安全名字
case "$SUB_TOKEN" in
    "") : ;;
    .*|*[!A-Za-z0-9._~-]*) die "SUB_TOKEN 只能含字母、数字和 . _ ~ -，且不能以点开头" ;;
esac

# 订阅内容输出目录：设置令牌时多一层 /<token>
out_dir() {
    if [ -n "$SUB_TOKEN" ]; then
        printf '%s/%s' "$SUB_DIR" "$SUB_TOKEN"
    else
        printf '%s' "$SUB_DIR"
    fi
}

url_prefix() {
    [ -n "$SUB_TOKEN" ] && printf '/%s' "$SUB_TOKEN"
    return 0
}

render_clash() {
    printf '# xray-reality 订阅（Clash / mihomo proxies）\n'
    printf '# 生成时间: %s\n' "$(jq -r '.generated // "-"' "$NODES")"
    printf 'proxies:\n'
    jq -r '.nodes[] |
        "  - name: \"\(.name)\"\n" +
        "    type: vless\n" +
        "    server: \(.address)\n" +
        "    port: \(.port)\n" +
        "    uuid: \(.uuid)\n" +
        "    network: tcp\n" +
        "    tls: true\n" +
        "    udp: true\n" +
        "    flow: \(.flow)\n" +
        "    servername: \(.sni)\n" +
        "    client-fingerprint: chrome\n" +
        "    reality-opts:\n" +
        "      public-key: \(.public_key)\n" +
        "      short-id: \(.short_id)"' "$NODES"
}

render_index() {
    local p
    p=$(url_prefix)
    cat <<EOF
<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>xray-reality 订阅</title>
<style>
body{font-family:-apple-system,"Segoe UI",Roboto,"Helvetica Neue",Arial,"PingFang SC","Microsoft YaHei",sans-serif;
     max-width:52rem;margin:2rem auto;padding:0 1rem;line-height:1.6;color:#1c1e21}
h1{font-size:1.4rem}h2{font-size:1.1rem;margin-top:1.6rem}
code,a{word-break:break-all}li{margin:.3rem 0}
table{border-collapse:collapse;width:100%;font-size:.9rem;margin-top:.5rem}
th,td{border:1px solid #d8dade;padding:.35rem .6rem;text-align:left}
th{background:#f4f5f7}
</style></head><body>
<h1>xray-reality 订阅</h1>
<p>节点数 <b>$(jq '.nodes | length' "$NODES")</b>　生成时间 <code>$(jq -r '.generated // "-"' "$NODES")</code></p>
<h2>订阅地址</h2>
<ul>
<li><code>$p/sub.txt</code> — base64，v2rayN / NekoBox / Shadowrocket / Clash Verge 等通用</li>
<li><code>$p/plain.txt</code> — 明文链接，一行一条</li>
<li><code>$p/clash.yaml</code> — Clash / mihomo proxies</li>
<li><code>$p/nodes.json</code> — 结构化节点信息</li>
</ul>
<h2>节点列表</h2>
<table>
<tr><th>节点</th><th>地址</th><th>端口</th><th>SNI</th><th>出口</th></tr>
EOF
    jq -r '.nodes[] |
        "<tr><td>\(.name|@html)</td><td>\(.address|@html)</td><td>\(.port)</td>" +
        "<td>\(.sni|@html)</td><td>" +
        (if (.proxy_url // "") == "" then "本机直连" else (.proxy_url|@html) end) +
        "</td></tr>"' "$NODES"
    printf '</table>\n</body></html>\n'
}

# 设置令牌时，根目录只放一个不含令牌的占位页（避免泄露令牌所在路径）
render_root() {
    cat <<'EOF'
<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8"><title>xray-reality 订阅</title></head>
<body>
<h1>xray-reality 订阅</h1>
<p>本订阅受访问令牌保护，请使用带令牌的地址（形如 <code>/&lt;token&gt;/sub.txt</code>）访问。</p>
<p>完整地址见 <code>docker logs xray-reality-sub</code> 的启动日志。</p>
</body></html>
EOF
}

# 生成全部订阅文件；先写隐藏临时文件再 mv，避免刷新瞬间被读到半个文件
gen() {
    local out
    [ -s "$NODES" ] || return 1
    out=$(out_dir)
    mkdir -p "$out"

    jq -r '.nodes[] | .link' "$NODES" > "$out/.plain.$$"
    mv "$out/.plain.$$" "$out/plain.txt"

    base64 -w 0 < "$out/plain.txt" > "$out/.sub.$$"
    printf '\n' >> "$out/.sub.$$"
    mv "$out/.sub.$$" "$out/sub.txt"

    render_clash > "$out/.clash.$$"
    mv "$out/.clash.$$" "$out/clash.yaml"

    cp "$NODES" "$out/.nodes.json.$$"
    mv "$out/.nodes.json.$$" "$out/nodes.json"

    render_index > "$out/.index.$$"
    mv "$out/.index.$$" "$out/index.html"

    if [ -n "$SUB_TOKEN" ]; then
        render_root > "$SUB_DIR/.index.$$"
        mv "$SUB_DIR/.index.$$" "$SUB_DIR/index.html"
    fi
    chmod -R a+rX "$SUB_DIR"
}

print_urls() {
    local base p
    p=$(url_prefix)
    base="${SUB_BASE_URL:-http://<服务器地址>:${SUB_PORT}}"
    log "订阅已生成，节点数 $(jq '.nodes | length' "$NODES")，地址："
    log "  通用 base64 : $base$p/sub.txt"
    log "  明文链接    : $base$p/plain.txt"
    log "  Clash YAML  : $base$p/clash.yaml"
    log "  节点 JSON   : $base$p/nodes.json"
}

serve() {
    local waited=0
    command -v darkhttpd >/dev/null 2>&1 || die "缺少 darkhttpd，请使用本仓库镜像"
    mkdir -p "$SUB_DIR"
    # 独立容器先于 xray 启动时，节点清单可能还没生成
    while [ ! -s "$NODES" ]; do
        [ "$waited" = "1" ] || log "等待节点清单 $NODES（需挂载同一配置卷，且 xray 已启动）"
        waited=1
        sleep 3
    done
    gen || die "订阅生成失败"
    print_urls
    if [ "$SUB_REFRESH" -gt 0 ] 2>/dev/null; then
        (
            while :; do
                sleep "$SUB_REFRESH"
                gen >/dev/null 2>&1 || true
            done
        ) &
        log "刷新间隔   : ${SUB_REFRESH}s"
    else
        log "刷新间隔   : 仅启动时生成一次（SUB_REFRESH=0）"
    fi
    log "监听地址   : ${SUB_ADDR}:${SUB_PORT}${SUB_TOKEN:+（令牌路径 /$SUB_TOKEN/）}"
    # --no-listing 禁止列目录（否则根目录会暴露令牌子目录名）；--chroot 锁进订阅目录
    exec darkhttpd "$SUB_DIR" --port "$SUB_PORT" --addr "$SUB_ADDR" --no-listing --chroot
}

case "${1:-gen}" in
    gen)
        [ -s "$NODES" ] || die "节点清单不存在: $NODES（先启动 xray 容器，或挂载正确的配置卷）"
        gen || die "订阅生成失败"
        print_urls
        ;;
    serve) serve ;;
    *) die "用法: $0 [gen|serve]" ;;
esac

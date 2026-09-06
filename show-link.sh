#!/bin/sh
# 从运行中的 xray-reality 容器读取身份参数，生成 vless 节点链接
# 用法: ./show-link.sh [容器名] [服务器公网IP]
#   容器名默认 xray-reality；公网 IP 不填则从宿主机自动探测
#   多实例清单模式下列出全部实例/用户的链接，单实例模式输出单条链接
set -eu

CONTAINER="${1:-xray-reality}"
if [ -z "${2:-}" ]; then
    SERVER_IP=$(curl -s -4 --max-time 10 https://api.ipify.org 2>/dev/null || true)
else
    SERVER_IP="$2"
fi
if [ -z "$SERVER_IP" ]; then
    echo "错误: 公网 IP 自动探测失败，请手动指定: $0 <容器名> <公网IP>" >&2
    exit 1
fi

# 多实例清单模式（优先用清单中每条线路自定义的 address，缺省回落到 SERVER_IP）
if docker exec "$CONTAINER" test -f /usr/local/etc/xray/instances.resolved.json 2>/dev/null; then
    docker exec -e SERVER_IP="$SERVER_IP" "$CONTAINER" sh -c '
        jq -r --arg ip "$SERVER_IP" '\''
            .[] | . as $ib | $ib.users[]
            | (if (.address // "") != "" then .address else $ip end) as $a
            | "vless://\(.uuid)@\($a):\($ib.port)?encryption=none&flow=xtls-rprx-vision&security=reality&sni=\($ib.sni)&fp=chrome&pbk=\($ib.public_key)&sid=\($ib.short_id)&type=tcp&headerType=none#\($ib.tag)-\(.name)"
        '\'' /usr/local/etc/xray/instances.resolved.json
    '
    exit 0
fi

# 单实例模式
docker exec -e SERVER_IP="$SERVER_IP" "$CONTAINER" sh -c '
    . /usr/local/etc/xray/meta.env
    echo "vless://$UUID@${SERVER_IP}:$PORT?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$SNI&fp=chrome&pbk=$PUBLIC_KEY&sid=$SHORT_ID&type=tcp&headerType=none#xray-reality"
'

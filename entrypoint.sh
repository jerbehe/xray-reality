#!/bin/sh
# Xray REALITY 容器入口：
# 1. 读取/生成身份参数（UUID、X25519 密钥），持久化在配置卷里，容器重建不变号
# 2. 生成 Xray 服务端配置并校验
# 3. 打印客户端连接信息，前台运行 xray
#
# 两种运行模式：
# A. 多实例清单模式：存在清单文件时启用，查找顺序 XRAY_INSTANCES >
#    /etc/xray-reality/instances.json（系统默认路径）> 配置卷 instances.json，
#    一个 xray 进程承载多个 REALITY 入站（多端口或多用户），每个用户可绑定不同出口代理。
#    清单格式（proxy/address 支持继承：user 未指定时继承入站级字段）：
#      [
#        { "name": "main", "port": 443, "sni": "www.amazon.com", "short_id": "88",
#          "address": "sg.example.com",                // 入站级连接地址（域名/IP），省略时用 SERVER_IP
#          "proxy": "socks5://host:port",              // 入站级默认出口，可省略
#          "users": [                                   // 省略 = 单个匿名用户（继承入站 proxy）
#            { "name": "alice", "uuid": "...", "proxy": "socks5://host:port",
#              "address": "a.example.com" },            // 用户级覆盖
#            { "name": "bob" }                          // 无 proxy = 本机直连出网
#          ],
#          "udp_policy": "block-quic"                   // 可选，覆盖全局 UDP_POLICY
#        }
#      ]
#    每实例的密钥与每用户的 UUID 持久化到 CONF_DIR/meta/<实例名>.env，删除该文件即重新生成身份。
# B. 单实例模式（向后兼容，以下环境变量）：
#   XRAY_PORT         监听端口，默认 443
#   XRAY_SNI          伪装域名，默认 www.amazon.com
#   XRAY_SHORT_ID     shortId，默认 88
#   XRAY_UUID         指定 UUID，不填自动生成
#   XRAY_PRIVATE_KEY  指定 REALITY 私钥（可只填此项，公钥自动推导）
#   XRAY_PUBLIC_KEY   与私钥配套的公钥
#
# 共有环境变量：
#   SERVER_IP         服务器公网 IP，不填则启动时自动探测（仅用于生成客户端链接）
#   XRAY_INSTANCES    多实例清单路径（默认查找 /etc/xray-reality/instances.json）
#   XRAY_BIN / XRAY_CONF_DIR  仅供本地调试覆盖，容器内无需设置
#
# 出口代理（单实例模式，或清单中各条线路未单独指定时也可用全局变量兜底）:
#   OUTBOUND_PROXY    代理地址，支持 socks5://[user:pass@]host:port、http(s)://[user:pass@]host:port
#                     未设置时回退读取 ALL_PROXY / all_proxy / HTTPS_PROXY / HTTP_PROXY
#                     用户名/密码含特殊字符时按 URL 编码书写（%40 = @）
#   UDP_POLICY        UDP 流量策略，默认 block-quic
#                       block-quic 阻断 UDP/443(QUIC)，其余 UDP 走代理（客户端自动回退 TCP）
#                       proxy      全部 UDP 走代理（要求代理支持 SOCKS5 UDP ASSOCIATE）
#                       direct     全部 UDP 本机直连（注意：出口 IP 与 TCP 不一致）
#                       block      全部 UDP 阻断
#   PROXY_BYPASS      绕过代理直连的目标，逗号分隔，如 geosite:cn,geoip:cn,192.168.0.0/16
#   NO_PROXY_ENV      设为 1 时忽略 ALL_PROXY 等标准变量，只认 OUTBOUND_PROXY
set -eu

XRAY_BIN="${XRAY_BIN:-/usr/local/bin/xray}"
CONF_DIR="${XRAY_CONF_DIR:-/usr/local/etc/xray}"
CONF="$CONF_DIR/config.json"
META="$CONF_DIR/meta.env"
CLIENT="$CONF_DIR/client.json"
META_DIR="$CONF_DIR/meta"
RESOLVED="$CONF_DIR/instances.resolved.json"
NODES="$CONF_DIR/nodes.json"

PORT="${XRAY_PORT:-443}"
SNI="${XRAY_SNI:-www.amazon.com}"
SHORT_ID="${XRAY_SHORT_ID:-88}"
UDP_POLICY="${UDP_POLICY:-block-quic}"
PROXY_BYPASS="${PROXY_BYPASS:-}"

die() {
    echo "[entrypoint] 错误: $*" >&2
    exit 1
}

# 解析出口代理地址：读取 OUTBOUND_PROXY，未设置时回退标准代理变量
resolve_proxy_url() {
    if [ -n "${OUTBOUND_PROXY:-}" ]; then
        printf '%s' "$OUTBOUND_PROXY"
        return
    fi
    [ "${NO_PROXY_ENV:-0}" = "1" ] && return
    for v in "${ALL_PROXY:-}" "${all_proxy:-}" "${HTTPS_PROXY:-}" "${https_proxy:-}" \
             "${HTTP_PROXY:-}" "${http_proxy:-}"; do
        if [ -n "$v" ]; then
            printf '%s' "$v"
            return
        fi
    done
}

urldecode() {
    # 纯 awk 实现（POSIX 兼容，不依赖 printf 的 \x 十六进制扩展）
    printf '%s' "$1" | awk '
    BEGIN { hex = "0123456789abcdef" }
    {
        s = $0; out = ""; i = 1
        while ((p = index(substr(s, i), "%")) > 0) {
            p += i - 1
            out = out substr(s, i, p - i)
            h = tolower(substr(s, p + 1, 2))
            if (length(h) == 2) {
                d = (index(hex, substr(h, 1, 1)) - 1) * 16 + index(hex, substr(h, 2, 1)) - 1
                out = out sprintf("%c", d)
                i = p + 3
            } else {
                out = out "%"
                i = p + 1
            }
        }
        printf "%s", out substr(s, i)
    }'
}

json_escape() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

valid_ipv4() {
    printf '%s' "$1" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || return 1
    printf '%s' "$1" | awk -F. 'NF!=4{exit 1} {for(i=1;i<=4;i++) if($i>255) exit 1}'
}

valid_domain() {
    printf '%s' "$1" | grep -qE '^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$'
}

valid_uuid() {
    printf '%s' "$1" | grep -qE '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
}

sanitize_tag() {
    printf '%s' "$1" | tr -c 'a-zA-Z0-9_-' '_' | sed -e 's/_*$//' -e 's/^_*//' -e 's/^$/unnamed/'
}

# 从 xray x25519 输出解析私钥/公钥（兼容新版 PrivateKey/Password 与旧版 Private key/Public key）
parse_keyout() {
    KEY_PRIVATE=$(printf '%s\n' "$1" | grep -iE 'private' | head -n1 | sed 's/^[^:]*: *//')
    KEY_PUBLIC=$(printf '%s\n' "$1" | grep -iE 'password|public' | head -n1 | sed 's/^[^:]*: *//')
}

gen_keypair() {
    local keyout
    keyout=$("$XRAY_BIN" x25519)
    parse_keyout "$keyout"
    [ -n "$KEY_PRIVATE" ] && [ -n "$KEY_PUBLIC" ] || die "X25519 密钥生成失败"
}

derive_public() {
    KEY_PUBLIC=$("$XRAY_BIN" x25519 -i "$1" \
        | grep -iE 'password|public' | head -n1 | sed 's/^[^:]*: *//')
    [ -n "$KEY_PUBLIC" ] || die "私钥无法推导公钥（私钥格式错误？）"
}

fetch_ip_from_url() {
    local url="$1" ip=""
    # --noproxy '*' 确保入口 IP 探测不受 ALL_PROXY 等环境变量影响：
    # 客户端要连的是本机公网 IP，不是出口代理的 IP
    case "$url" in
        *cdn-cgi/trace*)
            ip=$(curl -s -4 --noproxy '*' --connect-timeout 5 --max-time 10 "$url" 2>/dev/null \
                | sed -n 's/^ip=//p' | head -n1 | tr -d '\r\n')
            ;;
        *)
            ip=$(curl -s -4 --noproxy '*' --connect-timeout 5 --max-time 10 "$url" 2>/dev/null | tr -d '\r\n')
            ;;
    esac
    if valid_ipv4 "$ip"; then
        printf '%s' "$ip"
        return 0
    fi
    return 1
}

fetch_server_ip() {
    local url
    for url in \
        "https://www.cloudflare.com/cdn-cgi/trace" \
        "https://ipv4.icanhazip.com/" \
        "https://ipinfo.io/ip" \
        "https://api.ipify.org" \
        "https://checkip.amazonaws.com"; do
        if ip=$(fetch_ip_from_url "$url"); then
            printf '%s' "$ip"
            return 0
        fi
    done
    # IPv4 全部失败时尝试 IPv6
    local ip6
    ip6=$(curl -s -6 --noproxy '*' --connect-timeout 5 --max-time 10 \
        "https://www.cloudflare.com/cdn-cgi/trace" 2>/dev/null \
        | sed -n 's/^ip=//p' | head -n1 | tr -d '\r\n')
    case "$ip6" in
        *:*) printf '%s' "$ip6"; return 0 ;;
    esac
    return 1
}

# 确定对外 IP（仅影响客户端链接的显示，不影响服务端运行），写入 SERVER_IP
resolve_server_ip() {
    SERVER_IP="${SERVER_IP:-}"
    if [ -z "$SERVER_IP" ]; then
        SERVER_IP=$(fetch_server_ip || true)
    fi
    if [ -z "$SERVER_IP" ]; then
        echo "[entrypoint] 警告: 公网 IP 自动探测失败，请通过 -e SERVER_IP=x.x.x.x 指定" >&2
        SERVER_IP="<YOUR_SERVER_IP>"
    fi
}

# 经指定代理探测出口 IP（凭据用 --proxy-user 传入，避免密码中 @ : 被 URL 解析截断）
probe_exit_ip() {
    local proto="$1" host="$2" port="$3" tls="$4" user="$5" pass="$6" curl_proxy
    if [ "$proto" = "socks" ]; then
        curl_proxy="socks5h://$host:$port"
    elif [ "$tls" = "1" ]; then
        curl_proxy="https://$host:$port"
    else
        curl_proxy="http://$host:$port"
    fi
    if [ -n "$user" ]; then
        curl -s --connect-timeout 8 --max-time 15 -x "$curl_proxy" \
            --proxy-user "$user:$pass" \
            https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | sed -n 's/^ip=//p' | tr -d '\r\n'
    else
        curl -s --connect-timeout 8 --max-time 15 -x "$curl_proxy" \
            https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | sed -n 's/^ip=//p' | tr -d '\r\n'
    fi
}

# 拆解代理 URL，结果写入 PROXY_* 全局变量；地址非法时返回 1
parse_proxy_url() {
    local url="$1" scheme rest creds hostport
    scheme=$(printf '%s' "$url" | sed -n 's|^\([A-Za-z0-9]\{1,\}\)://.*|\1|p' | tr 'A-Z' 'a-z')
    case "$scheme" in
        socks|socks5|socks5h) PROXY_PROTO="socks"; PROXY_TLS=0 ;;
        http)                 PROXY_PROTO="http";  PROXY_TLS=0 ;;
        https)                PROXY_PROTO="http";  PROXY_TLS=1 ;;
        *) echo "[entrypoint] 错误: 不支持的代理协议 '${scheme:-空}'，仅支持 socks5:// http:// https://" >&2
           return 1 ;;
    esac
    rest=${url#*://}
    rest=${rest%/}
    case "$rest" in
        *@*) creds=${rest%@*}; hostport=${rest##*@} ;;
        *)   creds="";         hostport=$rest ;;
    esac
    case "$hostport" in
        \[*\]:*) PROXY_HOST=${hostport%]*}; PROXY_HOST=${PROXY_HOST#[}; PROXY_PORT=${hostport##*]:} ;;
        *:*)     PROXY_HOST=${hostport%:*};  PROXY_PORT=${hostport##*:} ;;
        *) echo "[entrypoint] 错误: 代理地址缺少端口: $url" >&2; return 1 ;;
    esac
    if [ -z "$PROXY_HOST" ] || ! printf '%s' "$PROXY_PORT" | grep -qE '^[0-9]{1,5}$' \
       || [ "$PROXY_PORT" -lt 1 ] || [ "$PROXY_PORT" -gt 65535 ]; then
        echo "[entrypoint] 错误: 代理地址非法: $url" >&2
        return 1
    fi
    PROXY_USER=""; PROXY_PASS=""
    if [ -n "$creds" ]; then
        PROXY_USER=$(urldecode "${creds%%:*}")
        case "$creds" in
            *:*) PROXY_PASS=$(urldecode "${creds#*:}") ;;
        esac
    fi
    return 0
}

# 生成代理出站 JSON（socks/http 两种协议，可带认证与 TLS）；$1 = 出站 tag，默认 proxy
build_proxy_outbound() {
    local tag="${1:-proxy}" users_json="" tls_json=""
    if [ -n "$PROXY_USER" ]; then
        users_json=$(printf ',
                    "users": [ { "user": "%s", "pass": "%s" } ]' \
            "$(json_escape "$PROXY_USER")" "$(json_escape "$PROXY_PASS")")
    fi
    [ "$PROXY_TLS" = "1" ] && tls_json=$(printf ',
            "streamSettings": { "security": "tls", "tlsSettings": { "serverName": "%s" } }' \
            "$(json_escape "$PROXY_HOST")")
    printf '{
            "tag": "%s",
            "protocol": "%s",
            "settings": {
                "servers": [
                    {
                        "address": "%s",
                        "port": %s%s
                    }
                ]
            }%s
        }' "$(json_escape "$tag")" "$PROXY_PROTO" "$(json_escape "$PROXY_HOST")" "$PROXY_PORT" "$users_json" "$tls_json"
}

# 解析 PROXY_BYPASS 逗号分隔列表，分类为域名/IP，写入 BYPASS_DOMAINS_JSON / BYPASS_IPS_JSON（JSON 数组字符串）
build_bypass_lists() {
    local item domains="" ips="" bd="" bi=""
    local IFS=','
    for item in $PROXY_BYPASS; do
        item=$(printf '%s' "$item" | tr -d ' ')
        [ -z "$item" ] && continue
        case "$item" in
            geoip:*|*/[0-9]*|[0-9]*.[0-9]*.[0-9]*.[0-9]*)
                bi="${bi:+$bi, }\"$(json_escape "$item")\"" ;;
            *)  bd="${bd:+$bd, }\"$(json_escape "$item")\"" ;;
        esac
    done
    unset IFS
    BYPASS_DOMAINS_JSON="[$bd]"
    BYPASS_IPS_JSON="[$bi]"
}

# 生成路由规则 JSON：私网直连 + UDP 策略 + 用户指定的绕过目标（单实例模式用）
build_routing_rules() {
    local rules="" item domains="" ips=""
    rules='{ "type": "field", "ip": [ "geoip:private" ], "outboundTag": "direct" }'
    case "$UDP_POLICY" in
        block-quic)
            rules="$rules,
            { \"type\": \"field\", \"network\": \"udp\", \"port\": 443, \"outboundTag\": \"block\" }" ;;
        direct)
            rules="$rules,
            { \"type\": \"field\", \"network\": \"udp\", \"outboundTag\": \"direct\" }" ;;
        block)
            rules="$rules,
            { \"type\": \"field\", \"network\": \"udp\", \"outboundTag\": \"block\" }" ;;
        proxy) : ;;
        *) echo "[entrypoint] 错误: UDP_POLICY 取值非法: $UDP_POLICY (block-quic|proxy|direct|block)" >&2
           return 1 ;;
    esac
    if [ -n "$PROXY_BYPASS" ]; then
        local IFS=','
        for item in $PROXY_BYPASS; do
            item=$(printf '%s' "$item" | tr -d ' ')
            [ -z "$item" ] && continue
            case "$item" in
                geoip:*|*/[0-9]*|[0-9]*.[0-9]*.[0-9]*.[0-9]*)
                    ips="${ips:+$ips, }\"$(json_escape "$item")\"" ;;
                *)  domains="${domains:+$domains, }\"$(json_escape "$item")\"" ;;
            esac
        done
        unset IFS
        [ -n "$domains" ] && rules="$rules,
            { \"type\": \"field\", \"domain\": [ $domains ], \"outboundTag\": \"direct\" }"
        [ -n "$ips" ] && rules="$rules,
            { \"type\": \"field\", \"ip\": [ $ips ], \"outboundTag\": \"direct\" }"
    fi
    printf '%s' "$rules"
}

# ================= 多实例清单模式 =================

# 校验清单基础结构（结构类错误直接终止）
manifest_validate() {
    command -v jq >/dev/null 2>&1 || die "清单模式需要 jq，请使用本仓库镜像或自行安装"
    jq -e 'type == "array" and length > 0' "$MANIFEST" >/dev/null 2>&1 \
        || die "清单不是非空 JSON 数组: $MANIFEST"
    jq -e 'all(.[]; (.name | type == "string" and length > 0))' "$MANIFEST" >/dev/null 2>&1 \
        || die "每个实例必须有非空 name"
    jq -e 'all(.[]; (.port | type == "number")) and all(.[]; (.port >= 1 and .port <= 65535))' "$MANIFEST" >/dev/null 2>&1 \
        || die "每个实例必须有合法 port (1-65535)"
    [ "$(jq '[.[].port] | length' "$MANIFEST")" = "$(jq '[.[].port] | unique | length' "$MANIFEST")" ] \
        || die "存在重复端口（同一端口只能被一个实例使用）"
    [ "$(jq '[.[].name] | length' "$MANIFEST")" = "$(jq '[.[].name] | unique | length' "$MANIFEST")" ] \
        || die "实例 name 重复"
    jq -e 'all(.[]; (.users // []) | type == "array")' "$MANIFEST" >/dev/null 2>&1 \
        || die "users 必须是数组"
    jq -e 'all(.[]; all((.users // [])[]; (.name | type == "string" and length > 0)))' "$MANIFEST" >/dev/null 2>&1 \
        || die "清单 users 中的每一项必须有非空 name"
    jq -e 'all(.[]; (((.users // []) | [.[].name] | unique | length) == ((.users // []) | length)))' "$MANIFEST" >/dev/null 2>&1 \
        || die "同一实例内用户 name 重复"
    jq -e 'all(.[]; all((.users // [])[]; ((.uuid // "") == "" or (.uuid | test("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")))))' "$MANIFEST" >/dev/null 2>&1 \
        || die "清单中存在非法 UUID"
    # 实例名清洗后仍须唯一（xray tag 不能撞）
    [ "$(jq '[.[].name]' "$MANIFEST")" = "$(jq '[.[].name | gsub("[^a-zA-Z0-9_-]"; "_")]' "$MANIFEST")" ] \
        || die "实例 name 含特殊字符，清洗后可能冲突，请改用字母数字-_"
}

manifest_url_list() {
    jq -r '[.[] | (.proxy // empty), ((.users // [])[] | (.proxy // empty))] | unique | .[]' "$MANIFEST"
}

# 逐实例解析身份（密钥/UUID 生成与持久化），生成 RESOLVED
manifest_resolve() {
    mkdir -p "$META_DIR"
    printf '[]' > "$RESOLVED.tmp"
    local count idx name tag metafile mpriv short policy ucount j uname ukey uuuid uproxy uaddr email users_json entry
    count=$(jq 'length' "$MANIFEST")
    idx=0
    while [ "$idx" -lt "$count" ]; do
        name=$(jq -r ".[$idx].name" "$MANIFEST")
        tag=$(sanitize_tag "$name")
        metafile="$META_DIR/$tag.env"
        # REALITY 密钥：清单指定 > 持久化复用 > 新生成
        mpriv=$(jq -r ".[$idx].private_key // \"\"" "$MANIFEST")
        if [ -n "$mpriv" ]; then
            derive_public "$mpriv"
            M_PRIV="$mpriv"; M_PUB="$KEY_PUBLIC"
        elif [ -f "$metafile" ]; then
            # shellcheck disable=SC1090
            . "$metafile"
            [ -n "${M_PRIV:-}" ] && [ -n "${M_PUB:-}" ] || die "实例 $name 的持久化密钥文件损坏: $metafile"
            echo "[entrypoint] 实例 $name 复用已有密钥（$metafile）"
        else
            gen_keypair
            M_PRIV="$KEY_PRIVATE"; M_PUB="$KEY_PUBLIC"
            echo "[entrypoint] 实例 $name 已生成新密钥"
        fi
        # shortId：清单指定 > 持久化 > 默认 88
        short=$(jq -r ".[$idx].short_id // \"\"" "$MANIFEST")
        if [ -z "$short" ] && [ -f "$metafile" ] && [ -n "${M_SHORT:-}" ]; then
            short="$M_SHORT"
        fi
        [ -n "$short" ] || short="88"
        # UDP 策略：实例级 > 全局
        policy=$(jq -r ".[$idx].udp_policy // \"\"" "$MANIFEST")
        [ -n "$policy" ] || policy="$UDP_POLICY"
        case "$policy" in
            block-quic|proxy|direct|block) : ;;
            *) die "实例 $name 的 udp_policy 取值非法: $policy (block-quic|proxy|direct|block)" ;;
        esac
        # SNI：实例级 > 全局默认
        sni=$(jq -r ".[$idx].sni // \"$SNI\"" "$MANIFEST")
        valid_domain "$sni" || die "实例 $name 的 SNI 域名格式非法: $sni"
        # 用户身份
        ucount=$(jq -r ".[$idx].users // [] | length" "$MANIFEST")
        [ "$ucount" -gt 0 ] || ucount=1
        users_json="[]"
        j=0
        while [ "$j" -lt "$ucount" ]; do
            uname=$(jq -r ".[$idx].users[$j].name // \"\"" "$MANIFEST")
            if [ -z "$uname" ]; then
                uname="$name"                      # 未提供 users 数组时的隐式单用户
                email="$name"
            else
                email="$name.$uname"               # 显式用户：email 保证全局唯一
            fi
            uuuid=$(jq -r ".[$idx].users[$j].uuid // \"\"" "$MANIFEST")
            if [ -z "$uuuid" ] && [ -f "$metafile" ]; then
                ukey="U_$(printf '%s' "$uname" | tr -c 'a-zA-Z0-9_' '_')"
                # shellcheck disable=SC1090
                uuuid=$(eval "printf '%s' \"\${$ukey:-}\"")
            fi
            if [ -z "$uuuid" ]; then
                uuuid=$("$XRAY_BIN" uuid)
            fi
            valid_uuid "$uuuid" || die "实例 $name 用户 $uname 的 UUID 非法"
            uproxy=$(jq -r ".[$idx].users[$j].proxy // .[$idx].proxy // \"\"" "$MANIFEST")
            # 连接地址：用户级 > 入站级 > SERVER_IP > 自动探测（空值 = 后两者兜底）
            uaddr=$(jq -r ".[$idx].users[$j].address // .[$idx].address // \"\"" "$MANIFEST")
            if [ -n "$uaddr" ]; then
                case "$uaddr" in
                    *:*) : ;;  # IPv6 字面量简单放行
                    *) valid_domain "$uaddr" || valid_ipv4 "$uaddr" \
                        || die "实例 $name 用户 $uname 的 address 非法: $uaddr（须为域名或 IP）" ;;
                esac
            fi
            users_json=$(jq -cn --argjson arr "$users_json" \
                --arg name "$uname" --arg email "$email" --arg uuid "$uuuid" --arg proxy "$uproxy" \
                --arg addr "$uaddr" \
                '$arr + [{ name: $name, email: $email, uuid: $uuid, proxy_url: $proxy, address: $addr }]')
            j=$((j + 1))
        done
        entry=$(jq -cn \
            --arg name "$name" --arg tag "$tag" --argjson port "$(jq -r ".[$idx].port" "$MANIFEST")" \
            --arg sni "$sni" \
            --arg short "$short" --arg priv "$M_PRIV" --arg pub "$M_PUB" --arg policy "$policy" \
            --argjson users "$users_json" \
            '{ name: $name, tag: $tag, port: $port, sni: $sni, short_id: $short,
               private_key: $priv, public_key: $pub, udp_policy: $policy, users: $users }')
        jq --argjson e "$entry" '. + [$e]' "$RESOLVED.tmp" > "$RESOLVED.tmp.new"
        mv "$RESOLVED.tmp.new" "$RESOLVED.tmp"
        # 持久化该实例身份（从 resolved 条目读取，兼容隐式单用户）
        {
            printf 'M_PRIV=%s\n' "$M_PRIV"
            printf 'M_PUB=%s\n' "$M_PUB"
            printf 'M_SHORT=%s\n' "$short"
            j=0
            while [ "$j" -lt "$ucount" ]; do
                uname=$(jq -r ".users[$j].name" <<EOF
$entry
EOF
)
                uuuid=$(jq -r ".users[$j].uuid" <<EOF
$entry
EOF
)
                printf 'U_%s=%s\n' "$(printf '%s' "$uname" | tr -c 'a-zA-Z0-9_' '_')" "$uuuid"
                j=$((j + 1))
            done
        } > "$metafile"
        chmod 600 "$metafile"
        idx=$((idx + 1))
    done
    mv "$RESOLVED.tmp" "$RESOLVED"
    chmod 600 "$RESOLVED"
}

# 渲染 config.json：jq 负责全部 JSON 编码
manifest_render() {
    local outmap="{}" outbounds="[]" urls url tag obj i
    urls=$(jq -r '[.[] | .users[] | .proxy_url | select(. != "")] | unique | .[]' "$RESOLVED")
    i=1
    for url in $urls; do
        tag="px$i"
        i=$((i + 1))
        parse_proxy_url "$url" || die "清单中的代理地址无法解析: $url"
        obj=$(build_proxy_outbound "$tag")
        outbounds=$(printf '%s' "$outbounds" | jq --argjson o "$obj" '. + [$o]')
        outmap=$(jq -cn --argjson m "$outmap" --arg url "$url" --arg tag "$tag" '$m + {($url): $tag}')
    done
    build_bypass_lists

    # 路由规则渲染器：私网直连 → 绕过列表 → 每实例 UDP 策略 → 每用户出站
    # 注意 --slurpfile 会把文件内容包成 [ [entry...] ]，因此用 $r[0] 取实例列表
    cat > /tmp/render.jq <<'JQEOF'
{
    log: { loglevel: "warning" },
    inbounds: [ $r[0][] | {
        tag: .tag,
        port: .port,
        protocol: "vless",
        settings: {
            clients: [ .users[] | { id: .uuid, flow: "xtls-rprx-vision", email: .email } ],
            decryption: "none"
        },
        streamSettings: {
            network: "tcp",
            security: "reality",
            realitySettings: {
                show: false,
                dest: (.sni + ":443"),
                xver: 0,
                serverNames: [ .sni ],
                privateKey: .private_key,
                minClientVer: "",
                maxClientVer: "",
                maxTimeDiff: 0,
                shortIds: [ .short_id ]
            }
        }
    } ],
    outbounds: (
        $outbounds
        + [ { tag: "direct", protocol: "freedom" }, { tag: "block", protocol: "blackhole" } ]
    ),
    routing: {
        domainStrategy: "AsIs",
        rules: (
            [ { type: "field", ip: [ "geoip:private" ], outboundTag: "direct" } ]
            + ( if ($bypass_domains | length) > 0 then
                  [ { type: "field", domain: $bypass_domains, outboundTag: "direct" } ]
                else [] end )
            + ( if ($bypass_ips | length) > 0 then
                  [ { type: "field", ip: $bypass_ips, outboundTag: "direct" } ]
                else [] end )
            + ( [ $r[0][] |
                  ( if .udp_policy == "block-quic" then
                      [ { type: "field", inboundTag: [ .tag ], network: "udp", port: 443, outboundTag: "block" } ]
                    elif .udp_policy == "direct" then
                      [ { type: "field", inboundTag: [ .tag ], network: "udp", outboundTag: "direct" } ]
                    elif .udp_policy == "block" then
                      [ { type: "field", inboundTag: [ .tag ], network: "udp", outboundTag: "block" } ]
                    else [] end ) ] | flatten )
            + [ $r[0][] | .users[] |
                ( if .proxy_url == "" then
                    { type: "field", user: [ .email ], outboundTag: "direct" }
                  else
                    { type: "field", user: [ .email ], outboundTag: $outmap[.proxy_url] }
                  end ) ]
        )
    }
}
JQEOF
    jq -n \
        --slurpfile r "$RESOLVED" \
        --argjson outbounds "$outbounds" \
        --argjson outmap "$outmap" \
        --argjson bypass_domains "$BYPASS_DOMAINS_JSON" \
        --argjson bypass_ips "$BYPASS_IPS_JSON" \
        -f /tmp/render.jq > "$CONF"
    chmod 600 "$CONF"
    rm -f /tmp/render.jq
}

# 写出统一节点清单 nodes.json：地址/端口/UUID/公钥/shortId/链接一应俱全，
# 供订阅服务（sub.sh）与自建脚本消费；两种运行模式输出同一份结构。
emit_nodes_json_multi() {
    jq --arg ip "${SERVER_IP:-}" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
        def frag: gsub("[^a-zA-Z0-9_-]"; "_");
        {
            generated: $now,
            nodes: [ .[] | . as $ib | $ib.users[] |
                (if (.address // "") != "" then .address else $ip end) as $a |
                ($ib.tag + "-" + (.name | frag)) as $nm |
                {
                    name: $nm, instance: $ib.name, user: .name,
                    address: $a, port: $ib.port, uuid: .uuid,
                    flow: "xtls-rprx-vision", sni: $ib.sni,
                    public_key: $ib.public_key, short_id: $ib.short_id,
                    udp_policy: $ib.udp_policy, proxy_url: .proxy_url,
                    link: ("vless://" + .uuid + "@" + $a + ":" + ($ib.port | tostring) +
                        "?encryption=none&flow=xtls-rprx-vision&security=reality&sni=" + $ib.sni +
                        "&fp=chrome&pbk=" + $ib.public_key + "&sid=" + $ib.short_id +
                        "&type=tcp&headerType=none#" + $nm)
                } ]
        }' "$RESOLVED" > "$NODES"
    chmod 600 "$NODES"
}

emit_nodes_json_single() {
    jq -n \
        --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg ip "$SERVER_IP" \
        --argjson port "$PORT" --arg uuid "$UUID" --arg sni "$SNI" \
        --arg pub "$PUBLIC_KEY" --arg sid "$SHORT_ID" --arg policy "$UDP_POLICY" \
        --arg proxy "${PROXY_URL:-}" --arg link "$LINK" \
        '{
            generated: $now,
            nodes: [ {
                name: "xray-reality", instance: "xray-reality", user: "",
                address: $ip, port: $port, uuid: $uuid,
                flow: "xtls-rprx-vision", sni: $sni,
                public_key: $pub, short_id: $sid,
                udp_policy: $policy, proxy_url: $proxy, link: $link
            } ]
        }' > "$NODES"
    chmod 600 "$NODES"
}

# 可选：设置 SUB_PORT 时在 xray 容器内一并拉起订阅服务（不设置则完全不启动）
maybe_start_sub() {
    [ -n "${SUB_PORT:-}" ] || return 0
    if [ ! -x /sub.sh ]; then
        echo "[entrypoint] 警告: 已设置 SUB_PORT 但 /sub.sh 不存在，跳过订阅服务" >&2
        return 0
    fi
    /sub.sh serve &
    echo "[entrypoint] 订阅服务已在容器内后台启动（端口 ${SUB_PORT}）"
}

# REALITY 握手自检：在回环地址上起一对临时 xray 客户端/服务端，验证该实例的
# SNI + 密钥 + shortId 能完成真实握手（部分站点如 www.microsoft.com 不能用作伪装目标，
# 失败时客户端表现为静默超时，必须提前发现）。成功返回 0。
reality_selftest() {
    local sni="$1" priv="$2" uuid="$3" short="$4" pub="$5"
    jq -n \
        --arg sni "$sni" --arg priv "$priv" --arg uuid "$uuid" \
        --arg short "$short" --arg pub "$pub" \
        '{
            log: { loglevel: "none" },
            inbounds: [
                { tag: "selfcli", listen: "127.0.0.1", port: 19999, protocol: "socks",
                  settings: { auth: "noauth", udp: false } },
                { tag: "selfsrv", listen: "127.0.0.1", port: 19998, protocol: "vless",
                  settings: { clients: [ { id: $uuid, flow: "xtls-rprx-vision", email: "self" } ],
                              decryption: "none" },
                  streamSettings: { network: "tcp", security: "reality",
                    realitySettings: { show: false, dest: ($sni + ":443"), xver: 0,
                      serverNames: [ $sni ], privateKey: $priv, shortIds: [ $short ] } } }
            ],
            outbounds: [
                { tag: "relay", protocol: "vless",
                  settings: { vnext: [ { address: "127.0.0.1", port: 19998,
                    users: [ { id: $uuid, encryption: "none", flow: "xtls-rprx-vision" } ] } ] },
                  streamSettings: { network: "tcp", security: "reality",
                    realitySettings: { serverName: $sni, fingerprint: "chrome",
                      publicKey: $pub, shortId: $short } } },
                { tag: "direct", protocol: "freedom" }
            ],
            routing: { rules: [ { type: "field", inboundTag: [ "selfsrv" ], outboundTag: "direct" } ] }
        }' > /tmp/selftest.json
    "$XRAY_BIN" run -config /tmp/selftest.json >/dev/null 2>&1 &
    local pid=$!
    local ok=0 attempt=0
    # xray 冷启动可能超过 1 秒，重试探测直至超时
    while [ "$attempt" -lt 3 ]; do
        sleep 1
        if curl -s -o /dev/null -w '%{http_code}' --connect-timeout 4 --max-time 8 \
            -x socks5h://127.0.0.1:19999 https://www.gstatic.com/generate_204 2>/dev/null | grep -q 204; then
            ok=1
            break
        fi
        attempt=$((attempt + 1))
    done
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    rm -f /tmp/selftest.json
    [ "$ok" = "1" ]
}

manifest_print_and_check() {
    # 存在未显式指定 address 的用户时才需要探测本机公网 IP
    if [ "$(jq '[.[] | .users[] | select((.address // "") == "")] | length' "$RESOLVED")" -gt 0 ]; then
        resolve_server_ip
    else
        SERVER_IP=""
    fi
    local count idx name tag port sni short pub policy ucount j uname email uuuid uproxy uaddr exit_ip
    echo "[entrypoint] ============ REALITY 多实例服务端已就绪 ============"
    count=$(jq 'length' "$RESOLVED")
    idx=0
    while [ "$idx" -lt "$count" ]; do
        name=$(jq -r ".[$idx].name" "$RESOLVED")
        tag=$(jq -r ".[$idx].tag" "$RESOLVED")
        port=$(jq -r ".[$idx].port" "$RESOLVED")
        sni=$(jq -r ".[$idx].sni" "$RESOLVED")
        short=$(jq -r ".[$idx].short_id" "$RESOLVED")
        pub=$(jq -r ".[$idx].public_key" "$RESOLVED")
        policy=$(jq -r ".[$idx].udp_policy" "$RESOLVED")
        ucount=$(jq -r ".[$idx].users | length" "$RESOLVED")
        echo "[entrypoint] ---- 实例 $name（端口 $port，SNI $sni，UDP 策略 $policy）----"
        if [ "${XRAY_SELFTEST:-1}" = "1" ]; then
            if reality_selftest "$sni" "$(jq -r ".[$idx].private_key" "$RESOLVED")" \
                "$(jq -r ".[$idx].users[0].uuid" "$RESOLVED")" "$short" "$pub"; then
                echo "[entrypoint]   REALITY 自检: 通过"
            else
                echo "[entrypoint] 警告: 实例 $name 的 REALITY 自检失败！SNI '$sni' 可能无法用作伪装目标" >&2
                echo "[entrypoint]   （可换一个支持 TLS1.3 的目标站点重试；客户端当前将无法连接该实例）" >&2
            fi
        fi
        j=0
        while [ "$j" -lt "$ucount" ]; do
            uname=$(jq -r ".[$idx].users[$j].name" "$RESOLVED")
            email=$(jq -r ".[$idx].users[$j].email" "$RESOLVED")
            uuuid=$(jq -r ".[$idx].users[$j].uuid" "$RESOLVED")
            uproxy=$(jq -r ".[$idx].users[$j].proxy_url" "$RESOLVED")
            uaddr=$(jq -r ".[$idx].users[$j].address" "$RESOLVED")
            if [ -n "$uproxy" ]; then
                exit_ip=$(probe_exit_ip_by_url "$uproxy")
                printf '[entrypoint]   用户 %-20s 出口=%s\n' "$email" "${exit_ip:-代理不通(警告)}"
                [ -n "$exit_ip" ] || echo "[entrypoint] 警告: 用户 $email 的代理无法访问外网，请检查" >&2
            else
                printf '[entrypoint]   用户 %-20s 出口=本机直连\n' "$email"
            fi
            [ -n "$uaddr" ] || uaddr="$SERVER_IP"
            printf '[entrypoint]   '
            printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp&headerType=none#%s-%s\n' \
                "$uuuid" "$uaddr" "$port" "$sni" "$pub" "$short" "$tag" "$(printf '%s' "$uname" | tr -c 'a-zA-Z0-9_-' '_')"
            j=$((j + 1))
        done
        idx=$((idx + 1))
    done
    echo "[entrypoint] 配置目录 : $CONF_DIR（instances.resolved.json / config.json / meta/）"
    emit_nodes_json_multi
    echo "[entrypoint] 节点清单 : $NODES（订阅服务 sub.sh 的数据源）"
}

# 按 URL 探测出口 IP（带进程内缓存，多个用户共用同一代理时只探测一次）
probe_exit_ip_by_url() {
    local url="$1" key
    key=$(printf '%s' "$url" | md5sum 2>/dev/null | cut -d' ' -f1 || printf '%s' "$url" | cksum | tr -d ' ')
    if printf '%s\n' "${_EXIT_CACHE_KEYS:-}" | grep -qxF "$key"; then
        # shellcheck disable=SC2086
        printf '%s\n' "$_EXIT_CACHE_KEYS" | grep -A1 -xF "$key" | tail -n1
        return 0
    fi
    parse_proxy_url "$url" || { printf '%s' ""; return 0; }
    local ip
    ip=$(probe_exit_ip "$PROXY_PROTO" "$PROXY_HOST" "$PROXY_PORT" "$PROXY_TLS" "$PROXY_USER" "$PROXY_PASS")
    _EXIT_CACHE_KEYS="${_EXIT_CACHE_KEYS:+$_EXIT_CACHE_KEYS
}$key
$ip"
    printf '%s' "$ip"
}

mkdir -p "$CONF_DIR"

# ================= 模式分发 =================
# 清单查找顺序：XRAY_INSTANCES 显式指定 > /etc/xray-reality/instances.json（系统默认）
#              > CONF_DIR/instances.json（旧版兼容）
if [ -n "${XRAY_INSTANCES:-}" ]; then
    MANIFEST="$XRAY_INSTANCES"
elif [ -f /etc/xray-reality/instances.json ]; then
    MANIFEST=/etc/xray-reality/instances.json
elif [ -f "$CONF_DIR/instances.json" ]; then
    MANIFEST="$CONF_DIR/instances.json"
else
    MANIFEST=""
fi

if [ -n "$MANIFEST" ]; then
    # 多实例清单模式
    [ -f "$MANIFEST" ] || die "XRAY_INSTANCES 指向的清单不存在: $MANIFEST"
    [ -n "${OUTBOUND_PROXY:-}${ALL_PROXY:-}${HTTPS_PROXY:-}${HTTP_PROXY:-}" ] && \
        echo "[entrypoint] 提示: 清单模式下忽略全局代理变量，请改用清单中每条线路的 proxy 字段" >&2
    manifest_validate
    manifest_resolve
    manifest_render
    if ! "$XRAY_BIN" run -test -config "$CONF" >/dev/null 2>&1; then
        echo "[entrypoint] 错误: Xray 配置校验失败，配置内容:" >&2
        cat "$CONF" >&2
        exit 1
    fi
    manifest_print_and_check
    maybe_start_sub
    exec "$XRAY_BIN" run -config "$CONF"
fi

# ================= 单实例模式（向后兼容，原有逻辑不变） =================

# 读取持久化的身份信息（挂载卷后容器重建不变号）
UUID="${XRAY_UUID:-}"
PRIVATE_KEY="${XRAY_PRIVATE_KEY:-}"
PUBLIC_KEY="${XRAY_PUBLIC_KEY:-}"
if [ -f "$META" ]; then
    echo "[entrypoint] 发现 $META，复用已有身份"
    # shellcheck disable=SC1090
    . "$META"
fi
# 显式传入的环境变量优先级最高（PORT/SNI/SHORT_ID 每次启动都可刷新）
PORT="${XRAY_PORT:-$PORT}"
SNI="${XRAY_SNI:-$SNI}"
SHORT_ID="${XRAY_SHORT_ID:-$SHORT_ID}"
UUID="${XRAY_UUID:-$UUID}"
PRIVATE_KEY="${XRAY_PRIVATE_KEY:-$PRIVATE_KEY}"
PUBLIC_KEY="${XRAY_PUBLIC_KEY:-$PUBLIC_KEY}"

# 生成缺失的身份参数
if [ -z "$UUID" ]; then
    UUID=$("$XRAY_BIN" uuid)
fi
if [ -z "$PRIVATE_KEY" ]; then
    gen_keypair
    PRIVATE_KEY="$KEY_PRIVATE"
    PUBLIC_KEY="$KEY_PUBLIC"
elif [ -z "$PUBLIC_KEY" ]; then
    # 只有私钥时推导公钥
    derive_public "$PRIVATE_KEY"
    PUBLIC_KEY="$KEY_PUBLIC"
fi
if [ -z "$UUID" ] || [ -z "$PRIVATE_KEY" ] || [ -z "$PUBLIC_KEY" ]; then
    die "UUID 或密钥生成失败"
fi

# 写回持久化文件
cat > "$META" <<EOF
PORT=$PORT
SNI=$SNI
UUID=$UUID
PRIVATE_KEY=$PRIVATE_KEY
PUBLIC_KEY=$PUBLIC_KEY
SHORT_ID=$SHORT_ID
EOF
chmod 600 "$META"

# 组装出站与路由：设置了出口代理时，默认出站为代理（xray 以第一个出站为默认）
PROXY_URL=$(resolve_proxy_url)
OUTBOUNDS_JSON=""
ROUTING_JSON=""
if [ -n "$PROXY_URL" ]; then
    if ! parse_proxy_url "$PROXY_URL"; then
        echo "[entrypoint] 已设置出口代理但地址无法解析，为避免流量以本机 IP 直接出网，启动中止" >&2
        exit 1
    fi
    rules=$(build_routing_rules) || exit 1
    OUTBOUNDS_JSON=$(printf '%s,
        { "tag": "direct", "protocol": "freedom" },
        { "tag": "block", "protocol": "blackhole" }' "$(build_proxy_outbound)")
    ROUTING_JSON=$(printf ',
    "routing": {
        "domainStrategy": "AsIs",
        "rules": [
            %s
        ]
    }' "$rules")
else
    OUTBOUNDS_JSON='{ "tag": "direct", "protocol": "freedom" },
        { "tag": "block", "protocol": "blackhole" }'
fi

cat > "$CONF" <<EOF
{
    "log": {
        "loglevel": "warning"
    },
    "inbounds": [
        {
            "port": $PORT,
            "protocol": "vless",
            "settings": {
                "clients": [
                    {
                        "id": "$UUID",
                        "flow": "xtls-rprx-vision"
                    }
                ],
                "decryption": "none"
            },
            "streamSettings": {
                "network": "tcp",
                "security": "reality",
                "realitySettings": {
                    "show": false,
                    "dest": "$SNI:443",
                    "xver": 0,
                    "serverNames": [
                        "$SNI"
                    ],
                    "privateKey": "$PRIVATE_KEY",
                    "minClientVer": "",
                    "maxClientVer": "",
                    "maxTimeDiff": 0,
                    "shortIds": [
                        "$SHORT_ID"
                    ]
                }
            }
        }
    ],
    "outbounds": [
        $OUTBOUNDS_JSON
    ]$ROUTING_JSON
}
EOF
chmod 600 "$CONF"

# 生成客户端参数文件
cat > "$CLIENT" <<EOF
{
    "代理模式": "vless",
    "地址": "由宿主机公网 IP 决定，见下方链接",
    "端口": $PORT,
    "UUID": "$UUID",
    "流控": "xtls-rprx-vision",
    "传输协议": "tcp",
    "公钥": "$PUBLIC_KEY",
    "底层传输": "reality",
    "SNI": "$SNI",
    "shortIds": "$SHORT_ID"
}
EOF
chmod 600 "$CLIENT"

# 配置校验
if ! "$XRAY_BIN" run -test -config "$CONF" >/dev/null 2>&1; then
    echo "[entrypoint] 错误: Xray 配置校验失败，配置内容:" >&2
    cat "$CONF" >&2
    exit 1
fi

resolve_server_ip

LINK="vless://$UUID@$SERVER_IP:$PORT?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$SNI&fp=chrome&pbk=$PUBLIC_KEY&sid=$SHORT_ID&type=tcp&headerType=none#xray-reality"

echo "[entrypoint] ============ REALITY 服务端已就绪 ============"
echo "[entrypoint] 监听端口 : $PORT"
echo "[entrypoint] SNI      : $SNI"
echo "[entrypoint] shortId  : $SHORT_ID"
echo "[entrypoint] UUID     : $UUID"
echo "[entrypoint] 公钥     : $PUBLIC_KEY"
echo "[entrypoint] 客户端链接:"
echo "$LINK"
echo "[entrypoint] 配置目录 : $CONF_DIR（meta.env/config.json/client.json）"
emit_nodes_json_single
echo "[entrypoint] 节点清单 : $NODES（订阅服务 sub.sh 的数据源）"

# 出口代理自检：打印代理连通性与出口 IP（失败只告警，不阻止启动）
if [ -n "$PROXY_URL" ]; then
    echo "[entrypoint] 出口代理 : $PROXY_PROTO://$PROXY_HOST:$PROXY_PORT${PROXY_USER:+ (带认证)}"
    echo "[entrypoint] UDP 策略 : $UDP_POLICY${PROXY_BYPASS:+；绕过直连: $PROXY_BYPASS}"
    exit_ip=$(probe_exit_ip "$PROXY_PROTO" "$PROXY_HOST" "$PROXY_PORT" "$PROXY_TLS" "$PROXY_USER" "$PROXY_PASS")
    if [ -n "$exit_ip" ]; then
        echo "[entrypoint] 出口 IP  : $exit_ip（客户端流量将从此 IP 出网）"
    else
        echo "[entrypoint] 警告: 无法经代理访问外网，客户端可能无法上网；请检查代理地址与连通性" >&2
    fi
else
    echo "[entrypoint] 出口代理 : 未设置（流量由本机直接出网）"
fi

maybe_start_sub

# 前台运行，作为容器主进程
exec "$XRAY_BIN" run -config "$CONF"

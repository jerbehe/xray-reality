# Xray VLESS + REALITY 服务镜像（由 reality.sh 一键脚本改造）
# 构建: docker build -t xray-reality .
# 运行: docker run -d --name xray-reality -p 443:443 xray-reality
FROM alpine:3.22

# 可固定 Xray 版本，或改为 latest
ARG XRAY_VERSION=v26.3.27

LABEL org.opencontainers.image.title="xray-reality" \
      org.opencontainers.image.description="Xray VLESS+REALITY server, converted from reality.sh" \
      org.opencontainers.image.version="${XRAY_VERSION}"

RUN apk add --no-cache ca-certificates curl jq unzip

# 下载并安装 Xray 二进制和 geo 资源文件
RUN set -eux; \
    arch="${TARGETARCH:-$(uname -m)}"; \
    case "$arch" in \
        x86_64|amd64)  zip_arch="64" ;; \
        aarch64|arm64) zip_arch="arm64-v8a" ;; \
        *) echo "不支持的架构: $arch" >&2; exit 1 ;; \
    esac; \
    if [ "$XRAY_VERSION" = "latest" ]; then \
        url="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${zip_arch}.zip"; \
    else \
        url="https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/Xray-linux-${zip_arch}.zip"; \
    fi; \
    curl -fsSL --retry 3 --connect-timeout 30 -o /tmp/xray.zip "$url"; \
    unzip -o /tmp/xray.zip -d /tmp/xray; \
    install -m 755 /tmp/xray/xray /usr/local/bin/xray; \
    mkdir -p /usr/local/share/xray /usr/local/etc/xray /etc/xray-reality; \
    install -m 644 /tmp/xray/geoip.dat /tmp/xray/geosite.dat /usr/local/share/xray/; \
    /usr/local/bin/xray version; \
    rm -rf /tmp/xray /tmp/xray.zip

COPY entrypoint.sh /entrypoint.sh
RUN chmod 755 /entrypoint.sh

ENV XRAY_LOCATION=/usr/local/etc/xray \
    XRAY_LOCATION_ASSET=/usr/local/share/xray

EXPOSE 443

# entrypoint 用 exec 启动 xray，PID 1 即 xray 进程
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD grep -qx xray /proc/1/comm || exit 1

ENTRYPOINT ["/entrypoint.sh"]

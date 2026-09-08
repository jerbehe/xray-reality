#!/bin/sh
# 容器健康检查：xray 必须在运行；订阅服务开启时（SUB_PORT 非 0）其 HTTP 端口也要可用。
# 由 Dockerfile 的 HEALTHCHECK 调用，退出码 0 = 健康。
set -u

grep -qx xray /proc/1/comm || exit 1

p="${SUB_PORT:-8080}"
case "$p" in
    # 0 或非数字 = 订阅服务关闭，只检查 xray
    0|*[!0-9]*) exit 0 ;;
esac

wget -q -O /dev/null "http://127.0.0.1:$p/"

#!/usr/bin/env bash
set -euo pipefail

INSTALL_URL="${GATEWAY_INSTALL_URL:-https://raw.githubusercontent.com/gagaapp/aiservice/main}"
# proxy_ssl_alpn 是 nginx 1.31.0 (2026-05-13) 引入的 stream 指令，1.27 会报
# unknown directive 直接退出。降版本前先确认 gateway 不再需要出境 ALPN。
NGINX_IMAGE="nginx:1.31"
CONF_DIR="/etc/gateway"

err() { echo "ERROR: $*" >&2; exit 1; }

need_root() {
  [ "$(id -u)" = "0" ] || err "请用 root 运行（sudo）"
}

ensure_docker() {
  command -v docker >/dev/null 2>&1 || err "需要 docker"
}

pull_image() {
  echo "==> 拉取镜像 ${NGINX_IMAGE}"
  docker pull "${NGINX_IMAGE}" || err "拉取镜像失败"
}

init_dirs() {
  echo "==> 初始化配置目录 ${CONF_DIR}"
  mkdir -p "${CONF_DIR}"
  touch "${CONF_DIR}/mappings.conf"
  mkdir -p "${CONF_DIR}/stream.d"
}

compose_url() {
  local file="$1"
  printf '%s/%s\n' "${INSTALL_URL%/}" "$file"
}

install_command() {
  echo "==> 下载 gateway 管理命令"
  local url; url="$(compose_url gateway)"
  curl -fsSL "$url" -o /usr/local/bin/gateway || err "下载失败"
  chmod +x /usr/local/bin/gateway
  echo "gateway 命令已安装到 /usr/local/bin/gateway"
}

main() {
  need_root
  ensure_docker
  pull_image
  init_dirs
  install_command
  echo "==> 安装完成，进入配置菜单"
  /usr/local/bin/gateway
}

# main guard: 被 source（测试）时不执行 main
if [ "${GATEWAY_LIB:-0}" != "1" ]; then
  main "$@"
fi

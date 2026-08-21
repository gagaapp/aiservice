#!/usr/bin/env bash
# 境内中转节点安装脚本。
#
# 装两个东西: gateway(go) 二进制(systemd 服务) 与 nginx 容器。三个本机参数
# ——对外端口、loopback 端口、证书目录——在这里指定, 之后可用 `gateway set` 改。
# 绑定哪台 tun-server 不在这里配: gateway 启动后按公网 IP 向 heihaweb 认领,
# 未授权的 IP 会被一直拒绝、永不进入服务态。
set -euo pipefail

INSTALL_URL="${GATEWAY_INSTALL_URL:-https://raw.githubusercontent.com/gagaapp/aiservice/main}"
# 渲染的配置用到 ssl_alpn —— 那是 stream 模块 1.21.4 才引入的指令, 更老的 nginx
# 会以 `unknown directive "ssl_alpn"` 启动失败(本地 1.21.1 实测)。换镜像前先确认
# 版本 >= 1.21.4。
NGINX_MIN_VERSION="1.21.4"
NGINX_IMAGE="${GATEWAY_NGINX_IMAGE:-nginx:1.27}"
CONF_DIR="/etc/gateway"
ENV_FILE="${CONF_DIR}/gateway.env"
BIN="/usr/local/bin/gateway-go"
CMD="/usr/local/bin/gateway"
UNIT="/etc/systemd/system/gateway.service"

# 默认值; 可用命令行参数覆盖。
LISTEN_PORT=443
LOOPBACK_PORT=8443
SSL_DIR="${CONF_DIR}/ssl"
CERT_NAME="server"
TLS_CA_FILE=""

err() { echo "ERROR: $*" >&2; exit 1; }

usage() {
  cat <<'EOF'
用法: gateway-install.sh [选项]

  --listen-port N     leaf 连接的对外端口 (默认 443)
  --loopback-port N   nginx 交给 gateway(go) 的本机端口 (默认 8443)
  --ssl-dir DIR       TLS_A 证书目录 (默认 /etc/gateway/ssl)
  --cert-name NAME    证书名, 对应 <DIR>/<NAME>.crt 与 .key (默认 server)
  --tls-ca-file PEM   校验 tun-server 证书用的信任锚(私有 CA)。
                      **换信任锚, 不是关校验** —— 生产用公有 CA 签发的真证书时
                      不需要它; staging/自签环境必须给, 否则跨境 TLS_B 一定失败。
EOF
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --listen-port)   LISTEN_PORT="$2"; shift 2 ;;
      --loopback-port) LOOPBACK_PORT="$2"; shift 2 ;;
      --ssl-dir)       SSL_DIR="$2"; shift 2 ;;
      --cert-name)     CERT_NAME="$2"; shift 2 ;;
      --tls-ca-file)   TLS_CA_FILE="$2"; shift 2 ;;
      -h|--help)       usage; exit 0 ;;
      *) err "未知参数: $1" ;;
    esac
  done
  [ "$LISTEN_PORT" != "$LOOPBACK_PORT" ] || err "对外端口与 loopback 端口不能相同"
}

need_root() { [ "$(id -u)" = "0" ] || err "请用 root 运行（sudo）"; }
ensure_docker() { command -v docker >/dev/null 2>&1 || err "需要 docker"; }

pull_image() {
  echo "==> 拉取镜像 ${NGINX_IMAGE}"
  # 境内拉 Docker Hub 大概率失败, 需要先配好镜像加速器或手动 docker load。
  docker pull "${NGINX_IMAGE}" || err "拉取镜像失败(境内通常需要先配置镜像加速器)"
}

compose_url() { printf '%s/%s\n' "${INSTALL_URL%/}" "$1"; }

install_files() {
  echo "==> 安装 gateway(go) 与管理命令"
  curl -fsSL "$(compose_url gateway-go)" -o "$BIN" || err "下载 gateway-go 失败"
  chmod +x "$BIN"
  curl -fsSL "$(compose_url gateway)" -o "$CMD" || err "下载 gateway 命令失败"
  chmod +x "$CMD"
}

write_env() {
  echo "==> 写入本机配置 ${ENV_FILE}"
  mkdir -p "$CONF_DIR" "$SSL_DIR"
  cat > "$ENV_FILE" <<EOF
# 由 gateway-install.sh 生成。这些是本机的物理属性, 不由 heihaweb 下发。
LISTEN_PORT=${LISTEN_PORT}
LOOPBACK_PORT=${LOOPBACK_PORT}
SSL_DIR=${SSL_DIR}
CERT_NAME=${CERT_NAME}
TLS_CA_FILE=${TLS_CA_FILE}
EOF
}

write_unit() {
  echo "==> 安装 systemd 服务"
  # nginx.conf 由 gateway(go) 在拿到下发配置后生成, 所以 -nginx-conf 指向
  # ${CONF_DIR}; -nginx-reload 走管理命令, 它会先 nginx -t 再热重载。
  cat > "$UNIT" <<EOF
[Unit]
Description=Netun gateway (domestic relay)
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=${ENV_FILE}
ExecStart=${BIN} \\
  -listen-port \${LISTEN_PORT} \\
  -loopback-port \${LOOPBACK_PORT} \\
  -ssl-dir /ssl \\
  -cert-name \${CERT_NAME} \\
  -nginx-conf ${CONF_DIR}/nginx.conf \\
  -nginx-reload '${CMD} restart-nginx' \\
  \${TLS_CA_FILE:+-tls-ca-file \${TLS_CA_FILE}}
Restart=always
RestartSec=3
LimitNOFILE=262144

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable gateway >/dev/null 2>&1 || true
}

main() {
  parse_args "$@"
  need_root
  ensure_docker
  pull_image
  install_files
  write_env
  write_unit

  echo
  echo "==> 安装完成"
  echo "对外端口 ${LISTEN_PORT} / loopback ${LOOPBACK_PORT} / 证书 ${SSL_DIR}/${CERT_NAME}.crt|.key"
  echo
  echo "接下来:"
  echo "  1) 把真实域名的证书放到 ${SSL_DIR}/${CERT_NAME}.crt 与 .key"
  echo "     必须是受信任 CA 签发 —— 自签证书是明显可疑信号。"
  echo "  2) systemctl start gateway   # 按本机公网 IP 向 heihaweb 认领"
  echo "  3) 在 heihaweb 后台认领本机并绑定一台 tun-server"
  echo "  4) gateway restart-nginx     # 配置下发后拉起/重载 nginx"
  echo
  echo "查看状态: gateway status"
}

# main guard: 被 source（测试）时不执行 main
if [ "${GATEWAY_LIB:-0}" != "1" ]; then
  main "$@"
fi

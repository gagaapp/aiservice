#!/usr/bin/env bash
#
# install.sh — 在境内服务器上安装/更新/卸载 gateway（境内中转节点）。
#
# 与 tun-server 的 install.sh 同构：从发布仓库（gitee 与 github 完全镜像）拉取与
# 本机架构匹配的最新二进制，注册 systemd 服务，并安装一个同名管理命令。差别在于
# gateway 还要管一个 nginx 容器，以及三个只属于这台机器的参数。
#
# 形态：
#   leaf ─境内─► nginx(终 TLS_A) ─loopback+proxy_protocol─► gateway(go)
#                                                             │ 每会话一条 TLS_B
#                                                             ▼  跨境
#                                                       tun-server(中继态)
#
# 用法（需 root）：
#   sudo ./install.sh                                  # 安装/更新，默认端口 443/8443
#   sudo ./install.sh --listen-port 8443               # leaf 连的对外端口
#   sudo ./install.sh --loopback-port 9443             # nginx 交给 gateway 的本机端口
#   sudo ./install.sh --ssl-dir /etc/ssl/mysite        # TLS_A 证书目录（宿主机路径）
#   sudo ./install.sh --cert-name mysite               # 证书名 → <dir>/<name>.crt|.key
#   sudo ./install.sh --tls-ca-file /etc/ssl/ca.pem    # 私有 CA（staging/自签环境必给）
#   sudo ./install.sh --name gw2                       # 自定义服务/命令名
#   sudo ./install.sh --no-docker-install              # 不自动装 docker（自己管）
#   sudo ./install.sh --no-mirror                      # 不配置境内镜像加速
#   sudo ./install.sh --log-level debug
#   sudo ./install.sh uninstall
#
# 一键远程（二选一，各自只用对应平台，不跨平台）：
#   curl -fsSL "https://gitee.com/hupengbo31/aiservice/raw/main/gateway-install.sh" | sudo bash
#   curl -fsSL "https://raw.githubusercontent.com/gagaapp/aiservice/main/gateway-install.sh" | sudo bash
#   # 追加参数示例： ... | sudo bash -s -- --listen-port 8443
#
# 说明：
# - 绑定哪台 tun-server、出境 SNI、transport、预热连接下限都**不在这里配**——gateway
#   启动后按本机公网 IP 向 heihaweb 认领，配置全部由控制面下发。未授权的 IP 会被
#   一直拒绝、永不进入服务态。
# - 这里只配这台机器的物理属性：端口、证书目录。TLS_A 私钥永远不进控制面。
# - 证书必须是真实域名 + 受信任 CA 签发；自签是明显可疑信号。本脚本不申请、不续期。
# - docker 缺失会自动安装（nginx 以容器运行）。已装 docker 的机器一律不碰其配置；
#   只有「本脚本刚装的 docker」且机器上还没有 /etc/docker/daemon.json 时，才会写一份
#   镜像加速配置——境内直连 Docker Hub 基本拉不动。用 --no-docker-install /
#   --no-mirror 可分别关掉这两件事。
#
set -euo pipefail

# ---- 仓库常量（与 tun-server install.sh 同源；公开仓库，切勿放密钥）----
PROVIDER="${TUN_PROVIDER:-github}"
REPO="aiservice"
case "${PROVIDER}" in
  gitee)
    OWNER="hupengbo31"
    API="https://gitee.com/api/v5"
    INSTALL_URL="https://gitee.com/${OWNER}/${REPO}/raw/main/gateway-install.sh"
    WEB_URL="https://gitee.com/${OWNER}/${REPO}"
    ;;
  github)
    OWNER="gagaapp"
    API="https://api.github.com"
    INSTALL_URL="https://raw.githubusercontent.com/${OWNER}/${REPO}/main/gateway-install.sh"
    WEB_URL="https://github.com/${OWNER}/${REPO}"
    ;;
  *) echo "ERROR: 未知 PROVIDER '${PROVIDER}'（只支持 gitee|github）" >&2; exit 1 ;;
esac
RELEASE_BIN="gateway"           # release 附件基名（build.sh 产出 gateway-linux-*）

# 渲染的 nginx.conf 用到 ssl_alpn 与 proxy_half_close —— 都是 stream 模块 1.21.4 才引入
# 的指令，更老的镜像会以 `unknown directive "ssl_alpn"` 启动失败（1.21.1 实测）。
# 换镜像前先确认版本。
NGINX_MIN_VERSION="1.21.4"
NGINX_IMAGE="${GATEWAY_NGINX_IMAGE:-nginx:1.27}"

# ---- 默认值（可被参数覆盖；已安装则从 env 文件继承）----
NAME="gateway"
ACTION="install"
LOG_LEVEL=""
LISTEN_PORT=""
LOOPBACK_PORT=""
SSL_DIR=""
CERT_NAME=""
TLS_CA_FILE=""
NO_DOCKER_INSTALL=0     # 自己管 docker 的运维可以关掉自动安装
NO_MIRROR=0             # 关掉境内镜像加速（境外机器或已有自定义配置时）

while [ $# -gt 0 ]; do
  case "$1" in
    --name)            NAME="${2:-}"; shift 2 ;;
    --name=*)          NAME="${1#--name=}"; shift ;;
    --log-level)       LOG_LEVEL="${2:-}"; shift 2 ;;
    --log-level=*)     LOG_LEVEL="${1#--log-level=}"; shift ;;
    --listen-port)     LISTEN_PORT="${2:-}"; shift 2 ;;
    --listen-port=*)   LISTEN_PORT="${1#--listen-port=}"; shift ;;
    --loopback-port)   LOOPBACK_PORT="${2:-}"; shift 2 ;;
    --loopback-port=*) LOOPBACK_PORT="${1#--loopback-port=}"; shift ;;
    --ssl-dir)         SSL_DIR="${2:-}"; shift 2 ;;
    --ssl-dir=*)       SSL_DIR="${1#--ssl-dir=}"; shift ;;
    --cert-name)       CERT_NAME="${2:-}"; shift 2 ;;
    --cert-name=*)     CERT_NAME="${1#--cert-name=}"; shift ;;
    --tls-ca-file)     TLS_CA_FILE="${2:-}"; shift 2 ;;
    --tls-ca-file=*)   TLS_CA_FILE="${1#--tls-ca-file=}"; shift ;;
    --no-docker-install) NO_DOCKER_INSTALL=1; shift ;;
    --no-mirror)       NO_MIRROR=1; shift ;;
    uninstall)         ACTION="uninstall"; shift ;;
    *) echo "ERROR: 未知参数 '$1'（用法见脚本头部注释）" >&2; exit 1 ;;
  esac
done
echo "${NAME}" | grep -qE '^[a-zA-Z0-9_-]+$' || { echo "ERROR: 名称只能含字母数字/_/-（got '${NAME}'）" >&2; exit 1; }
if [ -n "${LOG_LEVEL}" ]; then
  LOG_LEVEL="$(printf '%s' "${LOG_LEVEL}" | tr '[:upper:]' '[:lower:]')"
  case "${LOG_LEVEL}" in
    debug|info|warn|warning|error|fatal|off) : ;;
    *) echo "ERROR: --log-level 只能是 debug|info|warn|error|fatal|off（got '${LOG_LEVEL}'）" >&2; exit 1 ;;
  esac
fi

# ---- 由名称派生路径 ----
BIN_DIR="/usr/local/lib/${NAME}"
BIN_PATH="${BIN_DIR}/${NAME}"
WRAPPER="/usr/local/bin/${NAME}"
SERVICE_NAME="${NAME}"
SERVICE_PATH="/etc/systemd/system/${NAME}.service"
# sysctl drop-in: 摘掉本机端口/TIME_WAIT 天花板。用独立文件而不是改 sysctl.conf,
# 删掉它即可完全还原。
SYSCTL_DROPIN="/etc/sysctl.d/99-${NAME}.conf"
VERSION_FILE="${BIN_DIR}/.version"
LEVEL_FILE="${BIN_DIR}/loglevel"
LOG_DIR="${BIN_DIR}/logs"                 # 日志目录；进程默认就写 <二进制目录>/logs，unit 里再显式给一遍
LOG_FILE="${LOG_DIR}/gateway.log"         # 文件名是二进制里定死的，与 --name 无关
CONF_DIR="/etc/${NAME}"
ENV_FILE="${CONF_DIR}/${NAME}.env"
NGINX_CONF="${CONF_DIR}/nginx.conf"      # 由 gateway(go) 拿到下发配置后生成
CONTAINER="${NAME}-nginx"
# nginx 的访问日志写 stdout, 由 docker 收成 json 文件。docker 默认不限大小也不清理,
# 每条连接一行, 长跑会把磁盘吃满; 所以建容器时就给它定上限(单文件大小 × 保留份数)。
NGINX_LOG_MAX_SIZE="100m"
NGINX_LOG_MAX_FILE="3"

err() { echo "ERROR: $*" >&2; exit 1; }
[ "$(id -u)" = "0" ] || err "请用 root 运行（sudo）"

# ---- 卸载 ----
if [ "${ACTION}" = "uninstall" ]; then
  echo "==> 卸载 ${NAME}"
  systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
  systemctl disable "${SERVICE_NAME}" 2>/dev/null || true
  docker rm -f "${CONTAINER}" >/dev/null 2>&1 || true
  rm -f "${SERVICE_PATH}" "${WRAPPER}"
  rm -rf "${SERVICE_PATH}.d" "${BIN_DIR}"
  rm -f "${SYSCTL_DROPIN}"
  sysctl --system >/dev/null 2>&1 || true
  systemctl daemon-reload 2>/dev/null || true
  echo "已卸载（${CONF_DIR} 下的证书与配置未删除）"
  exit 0
fi

command -v curl      >/dev/null 2>&1 || err "需要 curl"
command -v systemctl >/dev/null 2>&1 || err "需要 systemd（systemctl 不存在）"

# ---- docker：没有就装 ----
# gateway 必须有 docker（nginx 以容器运行）。一键脚本不该在这里把人挡在门外，所以
# 缺了就自动装；已经有了就完全不碰——绝不去动一台已在用 docker 的机器的配置。
ensure_docker() {
  if command -v docker >/dev/null 2>&1; then
    docker info >/dev/null 2>&1 || { systemctl enable --now docker >/dev/null 2>&1 || true; }
    docker info >/dev/null 2>&1 || err "docker 已安装但守护进程起不来（systemctl status docker 看看）"
    echo "==> docker 已就绪（$(docker --version 2>/dev/null | head -1)）"
    return 0
  fi
  [ "${NO_DOCKER_INSTALL}" = "1" ] && err "未安装 docker，且指定了 --no-docker-install"

  echo "==> 未检测到 docker，开始安装"
  # 官方便捷脚本；gateway 按定义装在境内，默认走阿里云镜像，否则大概率卡死。
  # --mirror 只影响下载 docker 自身的软件源，与后面拉 nginx 镜像是两回事。
  local args=""
  [ "${NO_MIRROR}" = "1" ] || args="--mirror Aliyun"
  # shellcheck disable=SC2086
  if ! curl -fsSL --connect-timeout 30 --retry 2 https://get.docker.com | sh -s -- ${args}; then
    err "docker 自动安装失败。请手动安装后重跑，或用发行版包管理器：
       Debian/Ubuntu: apt-get update && apt-get install -y docker.io
       CentOS/RHEL:   yum install -y docker
     装好后重跑本脚本（已装好的部分会被覆盖重装，安全）"
  fi
  systemctl enable --now docker >/dev/null 2>&1 || true
  docker info >/dev/null 2>&1 || err "docker 装上了但守护进程起不来（systemctl status docker 看看）"
  echo "    已安装 $(docker --version 2>/dev/null | head -1)"

  # 只在「我们刚装的 docker」且「还没有 daemon.json」时配镜像加速：
  # 境内直连 Docker Hub 基本拉不动。绝不覆盖运维已有的配置。
  if [ "${NO_MIRROR}" != "1" ] && [ ! -f /etc/docker/daemon.json ]; then
    echo "    配置镜像加速（/etc/docker/daemon.json）"
    mkdir -p /etc/docker
    cat > /etc/docker/daemon.json <<'DAEMON'
{
  "registry-mirrors": [
    "https://docker.m.daocloud.io",
    "https://dockerproxy.com",
    "https://mirror.baidubce.com"
  ]
}
DAEMON
    systemctl restart docker >/dev/null 2>&1 || true
    docker info >/dev/null 2>&1 || err "配置镜像加速后 docker 起不来，请检查 /etc/docker/daemon.json"
  fi
}
ensure_docker

# ---- 继承已有配置：重装时不写 --xxx 就沿用旧值 ----
mkdir -p "${CONF_DIR}"
if [ -f "${ENV_FILE}" ]; then
  # shellcheck disable=SC1090
  . "${ENV_FILE}"
fi
LISTEN_PORT="${LISTEN_PORT:-${GW_LISTEN_PORT:-443}}"
LOOPBACK_PORT="${LOOPBACK_PORT:-${GW_LOOPBACK_PORT:-8443}}"
SSL_DIR="${SSL_DIR:-${GW_SSL_DIR:-${CONF_DIR}/ssl}}"
CERT_NAME="${CERT_NAME:-${GW_CERT_NAME:-server}}"
TLS_CA_FILE="${TLS_CA_FILE:-${GW_TLS_CA_FILE:-}}"

[ "${LISTEN_PORT}" != "${LOOPBACK_PORT}" ] || err "对外端口与 loopback 端口不能相同（都是 ${LISTEN_PORT}）——nginx 会把连接 proxy_pass 给自己"
for p in "${LISTEN_PORT}" "${LOOPBACK_PORT}"; do
  echo "${p}" | grep -qE '^[0-9]+$' && [ "${p}" -ge 1 ] && [ "${p}" -le 65535 ] || err "端口非法：${p}"
done

# ---- 识别架构 ----
case "$(uname -m)" in
  x86_64|amd64)  ARCH="amd64" ;;
  aarch64|arm64) ARCH="arm64" ;;
  *) err "不支持的架构：$(uname -m)（仅 amd64 / arm64）" ;;
esac
ASSET="${RELEASE_BIN}-linux-${ARCH}"
echo "==> 安装 ${NAME}（架构 linux/${ARCH}，来源 asset=${ASSET}）"

# ---- 解析最新 release 的下载地址 ----
echo "==> 查询最新 release"
LATEST="$(curl -fsS --connect-timeout 20 --retry 3 "${API}/repos/${OWNER}/${REPO}/releases/latest")" \
  || err "查询 latest 失败"
TAG="$(printf '%s' "${LATEST}" | tr -d '\r\n' | grep -oE '"tag_name":[[:space:]]*"[^"]*"' | head -1 | sed 's/.*: *"//;s/"$//')"
DL_URL="$(printf '%s' "${LATEST}" | tr -d '\r\n' \
  | grep -oE "\"browser_download_url\":[[:space:]]*\"[^\"]*${ASSET}\"" | head -1 | sed 's/.*: *"//;s/"$//')"
[ -n "${DL_URL}" ] || err "最新 release 未找到 ${ASSET}（该 release 是否由新版 build.sh/deploy.sh 发布？）"
RELEASED_AT="$(printf '%s' "${LATEST}" | tr -d '\r\n' | grep -oE '"published_at":[[:space:]]*"[^"]*"' | head -1 | sed 's/.*: *"//;s/"$//' || true)"
[ -n "${RELEASED_AT}" ] || RELEASED_AT="$(printf '%s' "${LATEST}" | tr -d '\r\n' | grep -oE '"created_at":[[:space:]]*"[^"]*"' | head -1 | sed 's/.*: *"//;s/"$//' || true)"
RELEASED_AT="${RELEASED_AT%%T*}"
echo "    版本：${TAG:-unknown}（发布日期：${RELEASED_AT:-unknown}）"

# ---- 下载并安装二进制 ----
TMP="$(mktemp)"; trap 'rm -f "${TMP}"' EXIT
echo "==> 下载二进制"
curl -fSL --connect-timeout 20 --retry 3 "${DL_URL}" -o "${TMP}" || err "下载失败"
head -c4 "${TMP}" | grep -q $'\x7f''ELF' || err "下载内容不是 ELF 二进制（可能是错误页）"
systemctl is-active --quiet "${SERVICE_NAME}" && systemctl stop "${SERVICE_NAME}" || true
mkdir -p "${BIN_DIR}" "${SSL_DIR}"
install -m 0755 "${TMP}" "${BIN_PATH}"
printf '%s\n%s\n' "${TAG:-unknown}" "${RELEASED_AT:-unknown}" > "${VERSION_FILE}"

# ---- 拉 nginx 镜像 ----
#
# 境内直连 Docker Hub 基本拉不动, 而且 `docker pull` **没有超时**, 会一直挂着 ——
# 这是最容易让人以为"装死了"的地方。这里的策略:
#
#   1. 本地已有该镜像 → 直接用, 不联网。
#   2. 直连试一次, 但**加超时**, 失败就往下走, 不挂死。
#   3. 依次从镜像站拉, 成功后 re-tag 成规范名 —— 这样后面 docker run 用的名字不变。
#
# 关键是第 3 步**不碰这台机器的 /etc/docker/daemon.json**: 已经在用 docker 的机器,
# 它的 registry 配置是运维的东西, 装个 gateway 不该去改。镜像站前缀只作用于这一次拉取。
MIRROR_PREFIXES="docker.m.daocloud.io docker.1ms.run hub.rat.dev dockerproxy.com"

run_timeout() {  # $1=秒, 其余=命令; 没有 timeout(1) 就直接跑
  local s="$1"; shift
  if command -v timeout >/dev/null 2>&1; then timeout "$s" "$@"; else "$@"; fi
}

pull_nginx() {
  echo "==> 准备 nginx 镜像 ${NGINX_IMAGE}（要求 >= ${NGINX_MIN_VERSION}）"
  if docker image inspect "${NGINX_IMAGE}" >/dev/null 2>&1; then
    echo "    本地已有，跳过拉取"
    return 0
  fi

  # 只给直连 20s: 通的话远快于此; 不通的话(境内常态)不该每次装都白等一分钟。
  echo "    直连 Docker Hub（最多等 20s）…"
  if run_timeout 20 docker pull "${NGINX_IMAGE}" >/dev/null 2>&1; then
    echo "    拉取成功"
    return 0
  fi
  echo "    直连超时或失败，改用境内镜像站"

  # nginx 是官方镜像, 在镜像站上的路径是 <mirror>/library/nginx:<tag>
  local repo="${NGINX_IMAGE%%:*}" tag="${NGINX_IMAGE##*:}" m src
  [ "${repo}" = "${tag}" ] && tag="latest"
  for m in ${MIRROR_PREFIXES}; do
    src="${m}/library/${repo}:${tag}"
    echo "    尝试 ${src}"
    if run_timeout 120 docker pull "${src}" >/dev/null 2>&1; then
      # 改回规范名: 后面 docker run 与管理命令用的都是 ${NGINX_IMAGE}, 不必知道从哪拉的
      docker tag "${src}" "${NGINX_IMAGE}"
      docker rmi "${src}" >/dev/null 2>&1 || true
      echo "    成功（经 ${m}）"
      return 0
    fi
  done

  err "nginx 镜像拉取失败：直连与所有镜像站都不通。可选办法：
     · 指定一个你能访问的镜像：GATEWAY_NGINX_IMAGE=<你的仓库>/nginx:1.27 重跑本脚本
     · 或在能联网的机器上 docker save ${NGINX_IMAGE} -o nginx.tar，传到本机 docker load -i nginx.tar 后重跑
     · 或自行在 /etc/docker/daemon.json 配 registry-mirrors 并 systemctl restart docker
       （本脚本不会去改这台机器已有的 docker 配置）"
}
pull_nginx

# ---- 写本机配置 ----
echo "==> 写入本机配置 ${ENV_FILE}"
cat > "${ENV_FILE}" <<ENV
# 由 install.sh 生成。这些是本机的物理属性，不由 heihaweb 下发。
# 绑定的 tun-server / SNI / transport / 预热连接下限全部来自控制面。
GW_LISTEN_PORT=${LISTEN_PORT}
GW_LOOPBACK_PORT=${LOOPBACK_PORT}
GW_SSL_DIR=${SSL_DIR}
GW_CERT_NAME=${CERT_NAME}
GW_TLS_CA_FILE=${TLS_CA_FILE}
ENV

# ---- 写 systemd unit ----
# 两个约定:
#   * 证书目录**同名挂载**进容器(宿主机路径 == 容器内路径), 所以 nginx.conf 里写的
#     就是宿主机上那个真实路径, 没有"宿主机视角 / 容器视角"两套语义。
#     挂目录不挂文件: bind mount 绑的是 inode, 而证书续期是"写新文件 + rename 替换",
#     挂文件的话容器里会永远看到旧证书。目录 inode 不变, 续期后直接生效。
#   * 端口等本机参数**不烧进 ExecStart**, 而是经 EnvironmentFile 引用 —— 否则改一个
#     端口就得重写 unit(或者像最初那样重跑整个安装脚本、连带重新下载二进制和镜像)。
#     现在 `gateway set` 只改 env 文件再重启即可, 不碰网络。
echo "==> 写入 systemd 服务 ${SERVICE_PATH}"
cat > "${SERVICE_PATH}" <<UNIT
[Unit]
Description=${NAME} (domestic relay for tun-server)
Documentation=${WEB_URL}
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=${ENV_FILE}
ExecStart=${BIN_PATH} -tls-ca-file \${GW_TLS_CA_FILE} -env-file ${ENV_FILE} -nginx-conf ${NGINX_CONF} -nginx-reload '${WRAPPER} restart-nginx' 
Restart=always
RestartSec=3
LimitNOFILE=1048576
Environment=LOG_LEVEL_FILE=${LEVEL_FILE}
# 日志文件目录：进程自己按天/按大小切并清理，不走 journald（见「<名称> logs」）
Environment=LOG_DIR=${LOG_DIR}
User=root

[Install]
WantedBy=multi-user.target
UNIT

if [ -n "${LOG_LEVEL}" ]; then
  echo "==> 设置日志级别 ${LOG_LEVEL}（写入 ${LEVEL_FILE}）"
  printf '%s\n' "${LOG_LEVEL}" > "${LEVEL_FILE}"
fi

# ---- 生成同名管理命令（占位符在安装期展开，运行期变量用 \$ 转义）----
echo "==> 安装管理命令 ${WRAPPER}"
cat > "${WRAPPER}" <<WRAP
#!/usr/bin/env bash
# ${NAME} 管理命令（由 install.sh 生成，请勿手改）
set -euo pipefail
NAME="${NAME}"
SERVICE="${SERVICE_NAME}"
BIN_PATH="${BIN_PATH}"
WRAPPER="${WRAPPER}"
SERVICE_PATH="${SERVICE_PATH}"
VERSION_FILE="${VERSION_FILE}"
LEVEL_FILE="${LEVEL_FILE}"
LOG_FILE="${LOG_FILE}"
INSTALL_URL="${INSTALL_URL}"
ENV_FILE="${ENV_FILE}"
NGINX_CONF="${NGINX_CONF}"
CONTAINER="${CONTAINER}"
NGINX_IMAGE="${NGINX_IMAGE}"
NGINX_LOG_MAX_SIZE="${NGINX_LOG_MAX_SIZE}"
NGINX_LOG_MAX_FILE="${NGINX_LOG_MAX_FILE}"

need_root() { [ "\$(id -u)" = "0" ] || { echo "需要 root：sudo \$NAME \$1" >&2; exit 1; }; }
load_env() { [ -f "\$ENV_FILE" ] && . "\$ENV_FILE" || true; }

nginx_running() { docker ps --filter "name=^\${CONTAINER}\$" --filter status=running -q | grep -q .; }

nginx_start() {
  load_env
  [ -f "\$NGINX_CONF" ] || { echo "还没有 \$NGINX_CONF —— 它由 \$NAME 拿到下发配置后生成。" >&2
                             echo "先确认本机公网 IP 已在 heihaweb 认领并绑定了一台 tun-server。" >&2; exit 1; }
  docker rm -f "\$CONTAINER" >/dev/null 2>&1 || true
  docker run -d --name "\$CONTAINER" --restart unless-stopped --network host \\
    --log-driver json-file --log-opt max-size="\$NGINX_LOG_MAX_SIZE" --log-opt max-file="\$NGINX_LOG_MAX_FILE" \\
    -v "\${NGINX_CONF}:/etc/nginx/nginx.conf:ro" \\
    -v "\${GW_SSL_DIR}:\${GW_SSL_DIR}:ro" \\
    "\$NGINX_IMAGE" >/dev/null
  echo "nginx 已启动（\$CONTAINER）"
}

# write_env 原子重写本机配置文件。这些值 systemd 经 EnvironmentFile 读, 所以改完
# 重启服务即可生效, 不需要重写 unit, 更不需要重跑安装脚本。
write_env() {
  local tmp; tmp="\$(mktemp)"
  cat > "\$tmp" <<ENV
# 由 \$NAME set / install.sh 生成。这些是本机的物理属性, 不由 heihaweb 下发。
# 绑定的 tun-server / SNI / transport / 预热连接下限全部来自控制面。
GW_LISTEN_PORT=\${GW_LISTEN_PORT}
GW_LOOPBACK_PORT=\${GW_LOOPBACK_PORT}
GW_SSL_DIR=\${GW_SSL_DIR}
GW_CERT_NAME=\${GW_CERT_NAME}
GW_TLS_CA_FILE=\${GW_TLS_CA_FILE}
ENV
  mv "\$tmp" "\$ENV_FILE"
}

print_conf() {
  load_env
  echo "对外端口(leaf 连这里) : \${GW_LISTEN_PORT:-?}"
  echo "loopback 端口         : \${GW_LOOPBACK_PORT:-?}"
  echo "证书                  : \${GW_SSL_DIR:-?}/\${GW_CERT_NAME:-?}.crt|.key"
  if [ -f "\${GW_SSL_DIR}/\${GW_CERT_NAME}.crt" ] && [ -f "\${GW_SSL_DIR}/\${GW_CERT_NAME}.key" ]; then
    echo "                        已就位"
  else
    echo "                        **缺失** —— 必须是真实域名 + 受信任 CA 签发"
  fi
  [ -n "\${GW_TLS_CA_FILE:-}" ] && echo "TLS_B 信任锚          : \${GW_TLS_CA_FILE}" || true
  echo
  echo "绑定的 tun-server、出境 SNI、transport、预热连接下限由 heihaweb 下发, 不在本机配。"
}

# gw_menu 是交互式菜单。它只是把下面那些子命令包一层 —— 所有动作仍走同一条路径,
# 菜单不额外实现逻辑, 免得两条路走偏。
gw_menu() {
  while :; do
    echo
    echo "===== \$NAME 管理菜单 ====="
    print_conf
    echo
    echo "  1) 查看运行状态"
    echo "  2) 修改本机配置（端口 / 证书目录 / 证书名 / 信任锚）"
    echo "  3) 启动          4) 停止          5) 重启"
    echo "  6) 查看日志（q 退出）"
    echo "  7) 重载 nginx    8) 启动 nginx    9) 停止 nginx"
    echo " 10) 查看 nginx 日志"
    echo " 11) 日志级别      12) 版本"
    echo " 13) 更新到最新版  14) 卸载"
    echo "  0) 退出"
    printf "请选择: "
    read -r choice || return 0
    case "\$choice" in
      1)  "\$WRAPPER" status ;;
      2)  gw_menu_set ;;
      3)  "\$WRAPPER" start   && echo "已启动" ;;
      4)  "\$WRAPPER" stop    && echo "已停止" ;;
      5)  "\$WRAPPER" restart && echo "已重启" ;;
      6)  "\$WRAPPER" logs ;;
      7)  "\$WRAPPER" restart-nginx ;;
      8)  "\$WRAPPER" nginx-start ;;
      9)  "\$WRAPPER" nginx-stop ;;
      10) "\$WRAPPER" nginx-logs ;;
      11) printf "级别(留空=查看当前) [debug|info|warn|error|fatal|off]: "; read -r lv
          if [ -n "\$lv" ]; then "\$WRAPPER" loglevel "\$lv"; else "\$WRAPPER" loglevel; fi ;;
      12) "\$WRAPPER" version ;;
      13) "\$WRAPPER" update ;;
      14) printf "确认卸载 \$NAME? 输入 yes 继续: "; read -r c
          [ "\$c" = "yes" ] && { "\$WRAPPER" uninstall; exit 0; } || echo "已取消" ;;
      0|q|Q) return 0 ;;
      *) echo "无效选择" ;;
    esac
  done
}

# gw_menu_set 交互式改本机配置。留空=保持不变, 与 set 的"不写的参数沿用旧值"一致。
gw_menu_set() {
  load_env
  echo "（直接回车 = 保持当前值不变）"
  printf "对外端口 [\${GW_LISTEN_PORT}]: ";   read -r v1
  printf "loopback 端口 [\${GW_LOOPBACK_PORT}]: "; read -r v2
  printf "证书目录 [\${GW_SSL_DIR}]: ";       read -r v3
  printf "证书名 [\${GW_CERT_NAME}]: ";       read -r v4
  printf "TLS_B 信任锚(私有 CA, 留空=用系统根) [\${GW_TLS_CA_FILE:-无}]: "; read -r v5
  args=""
  [ -n "\$v1" ] && args="\$args --listen-port \$v1"
  [ -n "\$v2" ] && args="\$args --loopback-port \$v2"
  [ -n "\$v3" ] && args="\$args --ssl-dir \$v3"
  [ -n "\$v4" ] && args="\$args --cert-name \$v4"
  [ -n "\$v5" ] && args="\$args --tls-ca-file \$v5"
  if [ -z "\$args" ]; then echo "没有改动"; return 0; fi
  # shellcheck disable=SC2086
  "\$WRAPPER" set \$args
}

case "\${1:-}" in
  show)     print_conf ;;
  set)
    # 改本机参数。只动 env 文件 + 重启, 不查 release、不下载二进制、不拉镜像 ——
    # 改一个端口不该付出重装的代价。
    need_root set
    shift
    load_env
    ssl_changed=0
    while [ \$# -gt 0 ]; do
      case "\$1" in
        --listen-port)     GW_LISTEN_PORT="\${2:-}"; shift 2 ;;
        --listen-port=*)   GW_LISTEN_PORT="\${1#--listen-port=}"; shift ;;
        --loopback-port)   GW_LOOPBACK_PORT="\${2:-}"; shift 2 ;;
        --loopback-port=*) GW_LOOPBACK_PORT="\${1#--loopback-port=}"; shift ;;
        --ssl-dir)         GW_SSL_DIR="\${2:-}"; ssl_changed=1; shift 2 ;;
        --ssl-dir=*)       GW_SSL_DIR="\${1#--ssl-dir=}"; ssl_changed=1; shift ;;
        --cert-name)       GW_CERT_NAME="\${2:-}"; shift 2 ;;
        --cert-name=*)     GW_CERT_NAME="\${1#--cert-name=}"; shift ;;
        --tls-ca-file)     GW_TLS_CA_FILE="\${2:-}"; shift 2 ;;
        --tls-ca-file=*)   GW_TLS_CA_FILE="\${1#--tls-ca-file=}"; shift ;;
        *) echo "未知参数 '\$1'。可改: --listen-port --loopback-port --ssl-dir --cert-name --tls-ca-file" >&2; exit 1 ;;
      esac
    done
    for p in "\$GW_LISTEN_PORT" "\$GW_LOOPBACK_PORT"; do
      echo "\$p" | grep -qE '^[0-9]+\$' && [ "\$p" -ge 1 ] && [ "\$p" -le 65535 ] \
        || { echo "端口非法：\$p" >&2; exit 1; }
    done
    # 相同端口会让 nginx 把连接 proxy_pass 给自己, 形成自环。
    [ "\$GW_LISTEN_PORT" != "\$GW_LOOPBACK_PORT" ] \
      || { echo "对外端口与 loopback 端口不能相同（都是 \$GW_LISTEN_PORT）" >&2; exit 1; }
    mkdir -p "\$GW_SSL_DIR"
    write_env
    echo "已更新本机配置："
    print_conf
    echo
    systemctl restart "\$SERVICE"
    echo "\$NAME 已重启（新参数生效）"
    # ssl 目录是容器的挂载源, 只有重建容器才会换 —— 会断开现有连接, 所以只在真的
    # 改了目录时才做。
    if [ "\$ssl_changed" = 1 ] && nginx_running; then
      echo "证书目录已变更，重建 nginx 容器（现有连接会断开）"
      nginx_start
    fi
    ;;
  start)    need_root start;   systemctl start "\$SERVICE" ;;
  stop)     need_root stop;    systemctl stop "\$SERVICE" ;;
  restart)  need_root restart; systemctl restart "\$SERVICE" ;;
  status)
    print_conf
    echo
    echo "--- \$NAME ---"; systemctl is-active "\$SERVICE" 2>/dev/null || true
    echo "--- nginx 容器 ---"; docker ps -a --filter "name=^\${CONTAINER}\$"
    ;;
  logs)
    # 跟随进程自己写的日志文件（-F：文件被切走后自动跟到新文件）；额外参数原样给 tail，
    # 如「logs -n 1000」。panic 等不走日志库的输出仍在 journalctl -u \$SERVICE。
    shift; [ "\$#" -eq 0 ] && set -- -n 200
    [ -f "\$LOG_FILE" ] || { echo "日志文件尚不存在：\$LOG_FILE（服务启动过吗？试试 \$NAME status）" >&2; exit 1; }
    exec tail "\$@" -F "\$LOG_FILE"
    ;;
  restart-nginx)
    # gateway(go) 在重写 nginx.conf 后会调用它。优先热重载(不断连)，未运行则拉起。
    #
    # 但热重载换不掉 bind mount —— ssl 目录是 docker run 时定死的。控制面把 ssl_dir
    # 改掉后, nginx.conf(文件挂载、原地重写)立刻指向新路径, 容器里却还是旧目录, 于是
    # nginx 一加载证书就 "cannot load certificate"。所以先确认容器真看得见 env 里那个
    # 目录; 看不见说明挂载已过时, 只能重建(会断开在途连接, 换挂载没有别的办法)。
    # 手工 \`set --ssl-dir\` 那条路径本来就会重建, 下发这条以前漏了。
    need_root restart-nginx
    load_env
    if nginx_running && docker exec "\$CONTAINER" test -d "\${GW_SSL_DIR:-}" 2>/dev/null; then
      docker exec "\$CONTAINER" nginx -t || { echo "配置校验失败，未重载" >&2; exit 1; }
      docker exec "\$CONTAINER" nginx -s reload
      echo "nginx 已重载（现有连接不受影响）"
    else
      nginx_running && echo "证书目录 \${GW_SSL_DIR:-?} 在容器内不可见（挂载已过时），重建容器（现有连接会断开）"
      nginx_start
    fi
    ;;
  nginx-start) need_root nginx-start; nginx_start ;;
  nginx-stop)  need_root nginx-stop; docker rm -f "\$CONTAINER" >/dev/null 2>&1 || true; echo "nginx 已停止" ;;
  nginx-logs)  exec docker logs -f "\$CONTAINER" ;;
  update)   need_root update;  curl -fsSL "\$INSTALL_URL" | bash -s -- --name "\$NAME" ;;
  version)
    VER="\$(sed -n 1p "\$VERSION_FILE" 2>/dev/null || true)"
    REL="\$(sed -n 2p "\$VERSION_FILE" 2>/dev/null || true)"
    echo "版本：\${VER:-unknown}"
    echo "发布日期：\${REL:-unknown}"
    ;;
  loglevel)
    shift
    if [ "\$#" -eq 0 ]; then
      [ -s "\$LEVEL_FILE" ] && head -1 "\$LEVEL_FILE" || echo "info（默认，未显式设置）"
      exit 0
    fi
    need_root loglevel
    LEVEL="\$(printf '%s' "\$1" | tr '[:upper:]' '[:lower:]')"
    case "\$LEVEL" in
      debug|info|warn|warning|error|fatal|off) : ;;
      *) echo "级别只能是 debug|info|warn|error|fatal|off（got '\$1'）" >&2; exit 1 ;;
    esac
    mkdir -p "\$(dirname "\$LEVEL_FILE")"
    printf '%s\n' "\$LEVEL" > "\$LEVEL_FILE"
    if systemctl is-active --quiet "\$SERVICE"; then
      systemctl kill -s HUP "\$SERVICE"
      echo "日志级别已设为 \$LEVEL 并热更新（未重启 \$NAME）"
    else
      echo "日志级别已写入 \$LEVEL（\$NAME 未运行，下次启动生效）"
    fi
    ;;
  uninstall)
    need_root uninstall
    systemctl stop "\$SERVICE" 2>/dev/null || true
    systemctl disable "\$SERVICE" 2>/dev/null || true
    docker rm -f "\$CONTAINER" >/dev/null 2>&1 || true
    rm -f "\$SERVICE_PATH" "\$WRAPPER"
    rm -rf "\${SERVICE_PATH}.d" "\$(dirname "\$BIN_PATH")"
    rm -f "${SYSCTL_DROPIN}"
    sysctl --system >/dev/null 2>&1 || true
    systemctl daemon-reload 2>/dev/null || true
    echo "已卸载 \$NAME（证书与配置未删除）"
    ;;
  menu) gw_menu ;;
  ""|help|-h|--help)
    # 不带子命令: 有终端就进菜单, 没有(管道/脚本/systemd 调用)就打印用法 ——
    # 菜单在非交互环境下会读到 EOF 死循环, 必须按 TTY 分流。
    #
    # help/-h/--help 一律直接打用法, 不进菜单: 明确问"支持哪些命令"的人要的是
    # 那张列表, 不是一个要交互的界面。
    if [ -z "${1:-}" ] && [ -t 0 ] && [ -t 1 ]; then gw_menu; exit 0; fi
    cat <<USAGE
\$NAME 管理命令：
  \$NAME                           不带参数进入交互菜单（需终端）
  \$NAME menu                      同上
  \$NAME show                      查看本机配置与证书状态
  \$NAME set [参数]                改本机配置（只改文件+重启，不下载任何东西）
                                  --listen-port / --loopback-port / --ssl-dir
                                  --cert-name / --tls-ca-file
  \$NAME start | stop | restart    启动 / 停止 / 重启 gateway
  \$NAME status                    本机配置 + 证书状态 + 两个组件的运行状态
  \$NAME logs [tail 参数]          跟随日志文件 \$LOG_FILE（默认最近 200 行起；如 \$NAME logs -n 1000）
  \$NAME loglevel [级别]           查看/设置日志级别（热更新不重启）
  \$NAME restart-nginx             重载 nginx（先校验配置；未运行则拉起）
  \$NAME nginx-start | nginx-stop | nginx-logs
  \$NAME update                    更新到最新版并重启
  \$NAME version                   显示已安装版本与发布日期
  \$NAME uninstall                 卸载

绑定哪台 tun-server、出境 SNI、transport、预热连接下限都由 heihaweb 下发，
本机只管端口与证书（用 \$NAME set 改，重装时不写的参数沿用旧值）。
USAGE
    ;;
  *)
    # 兜底: 没有它的话, 敲错的子命令会静默什么都不做、退出码还是 0 —— 运维会
    # 以为命令生效了。宁可吵一点。
    echo "未知命令: \$1" >&2
    echo "可用命令: \$NAME help" >&2
    exit 2
    ;;
esac
WRAP
chmod 0755 "${WRAPPER}"

# ---- 已在跑的 nginx 容器: 日志上限不对就重建 ----
# 日志上限是建容器时定死的, 而 update 之后 gateway 只会热重载 nginx(不重建容器),
# 所以老容器必须在这里重建一次才能带上新的上限。已经对的不碰, 免得每次 update 都白白重建。
# (重建会断开 leaf→nginx 的在途连接, 但紧接着的 systemctl restart 本来就会断掉全部会话。)
if docker inspect "${CONTAINER}" >/dev/null 2>&1; then
  cur_log="$(docker inspect --format '{{.HostConfig.LogConfig.Type}} {{index .HostConfig.LogConfig.Config "max-size"}} {{index .HostConfig.LogConfig.Config "max-file"}}' "${CONTAINER}" 2>/dev/null || true)"
  if [ "${cur_log}" != "json-file ${NGINX_LOG_MAX_SIZE} ${NGINX_LOG_MAX_FILE}" ]; then
    echo "==> nginx 容器的日志上限不是 ${NGINX_LOG_MAX_SIZE}×${NGINX_LOG_MAX_FILE}(当前: ${cur_log:-未知}), 重建容器"
    "${WRAPPER}" nginx-start || echo "警告: nginx 容器重建失败, 可手动执行 ${NAME} nginx-start"
  fi
fi

# ---- 摘掉本机的硬天花板 ----
#
# 数据面是 1:1 的: 每个用户会话占一条跨境 TCP 连接。默认的 sysctl 会在几万连接上
# 先撞墙, 而撞墙表现为 connect() 返回 EADDRNOTAVAIL —— 一个很难查的报错。
# 下面两项都是**摘天花板**, 不是限流:
#
#   * ip_local_port_range: 出向源端口数从默认约 2.8w 提到约 6.4w。
#   * tcp_tw_reuse: gateway 是主动连接方, 会话结束后源端口会压在 TIME_WAIT 60s。
#     这个选项允许出向连接复用它们(依赖 TCP 时间戳, 对主动连接方是安全的)。
#
#   * **不开 tcp_tw_recycle**: 现代内核已移除, 且会在 NAT 后误丢连接。
#
# 用 drop-in 而不是改 /etc/sysctl.conf: 卸载时删掉这个文件即可完全还原。
echo "==> 写入 sysctl(摘掉端口与 TIME_WAIT 的天花板)"
cat >"${SYSCTL_DROPIN}" <<'SYSCTL'
# 由 netun gateway 安装脚本写入。删除本文件即可完全还原。
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_tw_reuse = 1
SYSCTL
sysctl --system >/dev/null 2>&1 || echo "警告: sysctl 应用失败, 高并发下可能提前撞到端口上限"

# ---- 启用并启动 ----
echo "==> 启用并启动服务"
systemctl daemon-reload
systemctl enable "${SERVICE_NAME}" >/dev/null 2>&1 || true
systemctl restart "${SERVICE_NAME}"

sleep 1
echo
systemctl --no-pager --full status "${SERVICE_NAME}" | head -n 10 || true
echo
echo "==> 完成。本机配置："
echo "    对外端口 ${LISTEN_PORT}   loopback ${LOOPBACK_PORT}   证书 ${SSL_DIR}/${CERT_NAME}.crt|.key"
echo
echo "接下来："
echo "    1) 把真实域名的证书放到 ${SSL_DIR}/${CERT_NAME}.crt 与 .key"
echo "       必须受信任 CA 签发——自签是明显可疑信号。"
echo "    2) 在 heihaweb 后台认领本机公网 IP，并绑定一台 tun-server。"
echo "    3) ${NAME} restart-nginx     # 配置下发后拉起 nginx"
echo
echo "管理命令：${NAME} show / set / status / logs / restart-nginx / update / uninstall"
echo "改端口或证书目录：${NAME} set --listen-port 8443   （只改配置+重启，不重新下载）"
echo "提示：未在 heihaweb 认领的公网 IP 会被一直拒绝，gateway 不会进入服务态。"

#!/usr/bin/env bash
#
# install.sh — 在目标 Linux 服务器上安装/更新/卸载 tun-server。
#
# 从发布仓库（gitee 与 github 完全镜像）拉取与本机架构匹配的最新二进制，注册为
# systemd 服务，并安装一个同名管理命令（restart/logs/status/update/uninstall 等
# 常用操作）。默认从 gitee 下载；github 仓库里的同名脚本默认从 github 下载，两者
# 不跨平台兜底。
#
# 用法（需 root）：
#   sudo ./install.sh                       # 安装/更新，服务与命令名 = tun-server
#   sudo ./install.sh --name myvpn          # 自定义进程/服务/命令名为 myvpn
#   sudo ./install.sh --log-level debug     # 安装时设日志级别（debug|info|warn|error）
#   sudo ./install.sh uninstall             # 卸载 tun-server
#   sudo ./install.sh --name myvpn uninstall
#
# 一键远程（二选一，各自只用对应平台，不跨平台）：
#   curl -fsSL "https://gitee.com/hupengbo31/aiservice/raw/main/install.sh" | sudo bash
#   curl -fsSL "https://raw.githubusercontent.com/gagaapp/aiservice/main/install.sh" | sudo bash
#   # 追加参数示例： ... | sudo bash -s -- --name myvpn
#
# 说明：
# - 装好后用「<名称> <子命令>」管理，例如 tun-server restart / tun-server logs。
# - 调日志级别：「<名称> loglevel debug」运行期改并重启；不带参数则查看当前级别。
#   级别通过 systemd drop-in 的 LOG_LEVEL 环境变量生效，update 重装后保留。
# - 二进制无本地配置：启动后用公网 IP 登录 heihaweb（dash.heiha.vip）拉全部配置，
#   未注册 IP 会被拒绝。TLS cert/key 文件由运维按 heihaweb 下发路径预置；本脚本
#   只装二进制与服务，不处理证书。
#
set -euo pipefail

# ---- 仓库常量（aiservice 公开仓库：读取/下载无需 token，切勿在此放密钥）----
# 发布同时镜像到 gitee 与 github（两份完全相同的 release）。本脚本只从自己所在
# 平台下载，不跨平台兜底：PROVIDER 决定下载源。deploy.sh 同步到 github 仓库时会把
# 默认值渲染为 github；也可运行时用 TUN_PROVIDER=gitee|github 显式覆盖。
PROVIDER="${TUN_PROVIDER:-github}"
REPO="aiservice"
case "${PROVIDER}" in
  gitee)
    OWNER="hupengbo31"
    API="https://gitee.com/api/v5"
    INSTALL_URL="https://gitee.com/${OWNER}/${REPO}/raw/main/install.sh"
    WEB_URL="https://gitee.com/${OWNER}/${REPO}"
    ;;
  github)
    OWNER="gagaapp"
    API="https://api.github.com"
    INSTALL_URL="https://raw.githubusercontent.com/${OWNER}/${REPO}/main/install.sh"
    WEB_URL="https://github.com/${OWNER}/${REPO}"
    ;;
  *) echo "ERROR: 未知 PROVIDER '${PROVIDER}'（只支持 gitee|github）" >&2; exit 1 ;;
esac
RELEASE_BIN="tun-server"        # release 附件基名（deploy.sh 固定上传 tun-server-linux-*）

# ---- 解析参数：--name <名称> / --log-level <级别> / uninstall ----
NAME="tun-server"               # 默认进程/服务/命令名，--name 覆盖
ACTION="install"
LOG_LEVEL=""                    # 空=不写 drop-in，用二进制默认(info)；--log-level 覆盖
while [ $# -gt 0 ]; do
  case "$1" in
    --name)         NAME="${2:-}"; shift 2 ;;
    --name=*)       NAME="${1#--name=}"; shift ;;
    --log-level)    LOG_LEVEL="${2:-}"; shift 2 ;;
    --log-level=*)  LOG_LEVEL="${1#--log-level=}"; shift ;;
    uninstall)      ACTION="uninstall"; shift ;;
    *) echo "ERROR: 未知参数 '$1'（用法见脚本头部注释）" >&2; exit 1 ;;
  esac
done
echo "${NAME}" | grep -qE '^[a-zA-Z0-9_-]+$' || { echo "ERROR: 名称只能含字母数字/_/-（got '${NAME}'）" >&2; exit 1; }
# 日志级别允许为空（不设则用二进制默认 info）；非空则校验并归一化为小写
if [ -n "${LOG_LEVEL}" ]; then
  LOG_LEVEL="$(printf '%s' "${LOG_LEVEL}" | tr '[:upper:]' '[:lower:]')"
  case "${LOG_LEVEL}" in
    debug|info|warn|warning|error) : ;;
    *) echo "ERROR: --log-level 只能是 debug|info|warn|error（got '${LOG_LEVEL}'）" >&2; exit 1 ;;
  esac
fi

# ---- 由名称派生路径 ----
BIN_DIR="/usr/local/lib/${NAME}"          # 真正二进制目录（不进 PATH）
BIN_PATH="${BIN_DIR}/${NAME}"             # ExecStart 指向它，进程名即 ${NAME}
WRAPPER="/usr/local/bin/${NAME}"          # 同名管理命令（进 PATH）
SERVICE_NAME="${NAME}"
SERVICE_PATH="/etc/systemd/system/${NAME}.service"
VERSION_FILE="${BIN_DIR}/.version"

err() { echo "ERROR: $*" >&2; exit 1; }
[ "$(id -u)" = "0" ] || err "请用 root 运行（sudo）"

# ---- 卸载 ----
if [ "${ACTION}" = "uninstall" ]; then
  echo "==> 卸载 ${NAME}"
  systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
  systemctl disable "${SERVICE_NAME}" 2>/dev/null || true
  rm -f "${SERVICE_PATH}" "${WRAPPER}"
  rm -rf "${SERVICE_PATH}.d"
  rm -rf "${BIN_DIR}"
  systemctl daemon-reload 2>/dev/null || true
  echo "已卸载（证书等 host-local 文件未删除）"
  exit 0
fi

command -v curl     >/dev/null 2>&1 || err "需要 curl"
command -v systemctl >/dev/null 2>&1 || err "需要 systemd（systemctl 不存在）"

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
# 冒号后可能有空格：gitee 返回紧凑 JSON（无空格），github 返回带缩进 JSON（有空格），
# 故用 [[:space:]]* 兼容两者；sed 也用 ': *"' 剥掉键名（URL 内的 https:// 无 ': "' 序列，不误伤）
TAG="$(printf '%s' "${LATEST}" | tr -d '\r\n' | grep -oE '"tag_name":[[:space:]]*"[^"]*"' | head -1 | sed 's/.*: *"//;s/"$//')"
DL_URL="$(printf '%s' "${LATEST}" | tr -d '\r\n' \
  | grep -oE "\"browser_download_url\":[[:space:]]*\"[^\"]*${ASSET}\"" | head -1 | sed 's/.*: *"//;s/"$//')"
[ -n "${DL_URL}" ] || err "最新 release 未找到 ${ASSET}（仓库里有该架构产物吗？）"
echo "    版本：${TAG:-unknown}"

# ---- 下载并安装二进制 ----
TMP="$(mktemp)"; trap 'rm -f "${TMP}"' EXIT
echo "==> 下载二进制"
curl -fSL --connect-timeout 20 --retry 3 "${DL_URL}" -o "${TMP}" || err "下载失败"
head -c4 "${TMP}" | grep -q $'\x7f''ELF' || err "下载内容不是 ELF 二进制（可能是错误页）"
systemctl is-active --quiet "${SERVICE_NAME}" && systemctl stop "${SERVICE_NAME}" || true
mkdir -p "${BIN_DIR}"
install -m 0755 "${TMP}" "${BIN_PATH}"
printf '%s\n' "${TAG:-unknown}" > "${VERSION_FILE}"

# ---- 写 systemd unit（ExecStart=${BIN_PATH}，进程名即 ${NAME}）----
echo "==> 写入 systemd 服务 ${SERVICE_PATH}"
cat > "${SERVICE_PATH}" <<UNIT
[Unit]
Description=${NAME} (NTP relay gateway)
Documentation=${WEB_URL}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${BIN_PATH}
Restart=always
RestartSec=3
LimitNOFILE=1048576
# 监听 :443 需特权端口，且需读取 heihaweb 下发路径的 cert/key
User=root

[Install]
WantedBy=multi-user.target
UNIT

# ---- 可选：按 --log-level 写 systemd drop-in（覆盖 LOG_LEVEL 环境变量）----
# drop-in 独立于主 unit：update 重装会重写主 unit 但保留这里设的级别；运行期亦可
# 用「<名称> loglevel <级别>」修改。未指定 --log-level 时不创建（保留既有/默认）。
if [ -n "${LOG_LEVEL}" ]; then
  echo "==> 设置日志级别 LOG_LEVEL=${LOG_LEVEL}（systemd drop-in）"
  mkdir -p "${SERVICE_PATH}.d"
  printf '[Service]\nEnvironment=LOG_LEVEL=%s\n' "${LOG_LEVEL}" > "${SERVICE_PATH}.d/loglevel.conf"
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
INSTALL_URL="${INSTALL_URL}"

need_root() { [ "\$(id -u)" = "0" ] || { echo "需要 root：sudo \$NAME \$1" >&2; exit 1; }; }

case "\${1:-}" in
  start)    need_root start;   systemctl start "\$SERVICE" ;;
  stop)     need_root stop;    systemctl stop "\$SERVICE" ;;
  restart)  need_root restart; systemctl restart "\$SERVICE" ;;
  status)   systemctl --no-pager status "\$SERVICE" ;;
  enable)   need_root enable;  systemctl enable "\$SERVICE";  echo "已设开机自启" ;;
  disable)  need_root disable; systemctl disable "\$SERVICE"; echo "已取消开机自启" ;;
  logs)     shift; [ "\$#" -eq 0 ] && set -- -f; exec journalctl -u "\$SERVICE" "\$@" ;;
  update)   need_root update;  curl -fsSL "\$INSTALL_URL" | bash -s -- --name "\$NAME" ;;
  version)  cat "\$VERSION_FILE" 2>/dev/null || echo unknown ;;
  loglevel)
    # 不带参数：显示当前级别；带参数：写 drop-in 覆盖 LOG_LEVEL 并重启
    shift
    DROPIN="\${SERVICE_PATH}.d/loglevel.conf"
    if [ "\$#" -eq 0 ]; then
      if [ -f "\$DROPIN" ]; then
        grep -oE 'LOG_LEVEL=[a-zA-Z]+' "\$DROPIN" | head -1 | cut -d= -f2
      else
        echo "info（默认，未显式设置）"
      fi
      exit 0
    fi
    need_root loglevel
    LEVEL="\$(printf '%s' "\$1" | tr '[:upper:]' '[:lower:]')"
    case "\$LEVEL" in
      debug|info|warn|warning|error) : ;;
      *) echo "级别只能是 debug|info|warn|error（got '\$1'）" >&2; exit 1 ;;
    esac
    mkdir -p "\${SERVICE_PATH}.d"
    printf '[Service]\nEnvironment=LOG_LEVEL=%s\n' "\$LEVEL" > "\$DROPIN"
    systemctl daemon-reload
    systemctl restart "\$SERVICE"
    echo "日志级别已设为 \$LEVEL 并重启 \$NAME"
    ;;
  uninstall)
    need_root uninstall
    systemctl stop "\$SERVICE" 2>/dev/null || true
    systemctl disable "\$SERVICE" 2>/dev/null || true
    rm -f "\$SERVICE_PATH" "\$WRAPPER"
    rm -rf "\${SERVICE_PATH}.d"
    rm -rf "\$(dirname "\$BIN_PATH")"
    systemctl daemon-reload 2>/dev/null || true
    echo "已卸载 \$NAME（证书等 host-local 文件未删除）"
    ;;
  *)
    cat <<USAGE
\$NAME 管理命令：
  \$NAME start | stop | restart    启动 / 停止 / 重启服务
  \$NAME status                    查看运行状态
  \$NAME logs [journalctl 参数]    查看日志（默认 -f 跟随；如 \$NAME logs -n 100）
  \$NAME loglevel [级别]           查看/设置日志级别（debug|info|warn|error，设后自动重启）
  \$NAME enable | disable          开机自启 开 / 关
  \$NAME update                    更新到最新版并重启
  \$NAME version                   显示已安装版本
  \$NAME uninstall                 卸载
USAGE
    ;;
esac
WRAP
chmod 0755 "${WRAPPER}"

# ---- 启用并启动 ----
echo "==> 启用并启动服务"
systemctl daemon-reload
systemctl enable "${SERVICE_NAME}" >/dev/null 2>&1 || true
systemctl restart "${SERVICE_NAME}"

sleep 1
echo
systemctl --no-pager --full status "${SERVICE_NAME}" | head -n 10 || true
echo
echo "==> 完成。管理命令（开头为 ${NAME}）："
echo "    ${NAME} status      查看状态"
echo "    ${NAME} logs        看日志（-f 跟随）"
echo "    ${NAME} loglevel    查看/设置日志级别（如 ${NAME} loglevel debug）"
echo "    ${NAME} restart     重启"
echo "    ${NAME} update      更新到最新版"
echo "    ${NAME} uninstall   卸载"
echo "    ${NAME}             显示全部子命令"
echo
echo "提示：未在 heihaweb 注册的公网 IP 会被拒绝；证书需按 heihaweb 下发路径预置。"

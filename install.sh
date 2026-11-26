#!/usr/bin/env bash
###############################################################################
# vps-onekey / install.sh
# 一键搭建 VLESS + Reality + Vision 代理（Xray-core）
#
# 适配：Debian 11/12、Ubuntu 22.04/24.04（需 root）
#
# 三种用法：
#   1) 交互式（新手推荐，一路回车用默认值）：
#        ./install.sh
#   2) 命令行参数（自动化 / 非交互）：
#        ./install.sh --port 443 --sni www.microsoft.com --name mynode
#   3) 配置文件（适合批量/可复现部署）：
#        ./install.sh --config ./my.conf
#      配置文件为 KEY=value 行，可用本目录 config.example.txt 作模板
#
# 可配置项（括号内为默认值）：
#   PORT(543)           监听的 TCP 端口；543 可规避部分软路由对 443 的 SNI 劫持
#   SNI(www.apple.com)  伪装域名（ServerName），需为支持 TLS1.3+H2 的真实大站
#   NODE_NAME(Reality-Node) 节点显示名
#   FORCE_REGEN(0)      设 1 强制重新生成全部密钥（旧客户端会失效）
#
# 本方案为 IP 直连，无需自备域名；云控制台需放行入站 TCP <PORT>。
#
# Copyright (c) 2026 TheMrxk. Licensed under GPL-3.0-only.
###############################################################################
set -euo pipefail

WORKDIR="/etc/vps-onekey"
CRED_FILE="${WORKDIR}/cred.env"
XRAY_CONF="/usr/local/etc/xray/config.json"
LINK_FILE="${WORKDIR}/node-link.txt"
MIHOMO_FILE="${WORKDIR}/mihomo-node.yaml"

# ----------------------------- 输出工具 -------------------------------------
c_red()  { printf '\033[31m%s\033[0m\n' "$*"; }
c_grn()  { printf '\033[32m%s\033[0m\n' "$*"; }
c_ylw()  { printf '\033[33m%s\033[0m\n' "$*"; }
c_blue() { printf '\033[36m%s\033[0m\n' "$*"; }
c_bold() { printf '\033[1m%s\033[0m' "$*"; }
die()    { c_red "✘ $*"; exit 1; }
step()   { echo; c_blue "── $* ────────────────────────────"; }
trap 'c_red "脚本在第 $LINENO 行异常退出，可用 uninstall.sh 回滚"' ERR

# ----------------------------- 默认值 ---------------------------------------
PORT="543"
SNI="www.apple.com"
NODE_NAME="Reality-Node"
FORCE_REGEN="0"
CFG_FROM_FILE=""

# ----------------------------- 参数解析 -------------------------------------
# 支持 --port 443 / --port=443 两种写法，以及 --config 文件
while [ $# -gt 0 ]; do
  case "$1" in
    --config)       CFG_FROM_FILE="$2"; shift 2 ;;
    --config=*)     CFG_FROM_FILE="${1#*=}"; shift ;;
    --port)         PORT="$2"; shift 2 ;;
    --port=*)       PORT="${1#*=}"; shift ;;
    --sni)          SNI="$2"; shift 2 ;;
    --sni=*)        SNI="${1#*=}"; shift ;;
    --name)         NODE_NAME="$2"; shift 2 ;;
    --name=*)       NODE_NAME="${1#*=}"; shift ;;
    --force-regen)  FORCE_REGEN="1"; shift ;;
    -h|--help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "未知参数: $1（用 --help 查看用法）" ;;
  esac
done

# 配置文件优先级最低：先加载文件，命令行显式参数可在调用前覆盖
if [ -n "$CFG_FROM_FILE" ]; then
  [ -f "$CFG_FROM_FILE" ] || die "配置文件不存在: $CFG_FROM_FILE"
  # shellcheck disable=SC1090
  . "$CFG_FROM_FILE"
fi

# ----------------------------- 输入校验 -------------------------------------
validate_port() { case "$1" in ''|*[!0-9]*) return 1;; esac; [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }
validate_sni()  { echo "$1" | grep -Eq '^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$'; }

# ----------------------------- 交互式询问 -----------------------------------
# 仅当 stdin 接在终端上时进入；管道/CI 环境自动跳过，保证非交互可用
if [ -t 0 ]; then
  echo
  c_bold "════════ VPS-OneKey 交互式配置 ════════"; echo; echo
  c_ylw "每项都有默认值，直接回车即可采用括号内的值。"; echo

  read -rp "$(c_bold "监听端口 [${PORT}]：")" ans
  [ -n "$ans" ] && PORT="$ans"
  until validate_port "$PORT"; do
    c_red "端口需为 1-65535 的整数，请重填"
    read -rp "$(c_bold "监听端口 [${PORT}]：")" ans; [ -n "$ans" ] && PORT="$ans"
  done

  read -rp "$(c_bold "伪装域名 SNI [${SNI}]：")" ans
  [ -n "$ans" ] && SNI="$ans"
  until validate_sni "$SNI"; do
    c_red "域名格式不正确（示例 www.apple.com），请重填"
    read -rp "$(c_bold "伪装域名 SNI [${SNI}]：")" ans; [ -n "$ans" ] && SNI="$ans"
  done

  read -rp "$(c_bold "节点显示名 [${NODE_NAME}]：")" ans
  [ -n "$ans" ] && NODE_NAME="$ans"

  echo
  c_ylw "确认配置 → 端口:${PORT}  SNI:${SNI}  节点名:${NODE_NAME}"
  read -rp "$(c_bold "回车开始安装，输入 n 取消：")" go
  [ "$go" = "n" ] || [ "$go" = "N" ] && { c_red "已取消"; exit 0; }
else
  # 非交互模式仍做合法性校验，不合格直接失败而不是带病安装
  validate_port "$PORT" || die "PORT 非法: $PORT"
  validate_sni  "$SNI"  || die "SNI 非法: $SNI"
fi

DEST="${SNI}:443"
FLOW="xtls-rprx-vision"

# ----------------------------- 前置检查 -------------------------------------
[ "$(id -u)" -eq 0 ] || die "请用 root 运行：sudo ./install.sh"
command -v apt-get >/dev/null 2>&1 || die "当前仅支持 Debian/Ubuntu（apt 系），请改用对应系统"
step "系统信息"
. /etc/os-release && echo "OS: ${PRETTY_NAME}  内核: $(uname -r)"
mkdir -p "${WORKDIR}"

# ----------------------------- 0. 依赖检测与自动安装 -------------------------
# 集中声明：脚本运行所需的全部系统包；缺失才装，已装跳过，装失败明确报错
REQUIRED_PKGS="curl openssl ca-certificates wget unzip procps iproute2"
ensure_deps() {
  step "检测运行环境依赖（缺失自动安装）"
  export DEBIAN_FRONTEND=noninteractive
  # 先刷新软件源，失败给出可操作提示而不是带着残缺环境继续
  if ! apt-get update -qq; then
    die "apt-get update 失败，请检查服务器网络或软件源（/etc/apt/sources.list）后重试"
  fi
  local missing=""
  # 命令 -> 提供该命令的包 的映射，逐个用 command -v 实测，而非假设已装
  local check; check="curl:curl openssl:openssl wget:wget unzip:unzip sysctl:procps ss:iproute2"
  for pair in ${check}; do
    local cmd="${pair%%:*}" pkg="${pair##*:}"
    if ! command -v "${cmd}" >/dev/null 2>&1; then
      missing="${missing} ${pkg}"
      c_ylw "缺少命令 ${cmd}（将安装 ${pkg}）"
    fi
  done
  # ca-certificates 无独立命令，用文件存在性判断
  [ -s /etc/ssl/certs/ca-certificates.crt ] || missing="${missing} ca-certificates"
  if [ -n "${missing// }" ]; then
    echo "正在安装缺失依赖：${missing}"
    # shellcheck disable=SC2086
    if ! apt-get install -y -qq ${missing}; then
      die "依赖安装失败：${missing}，请手动执行 apt-get install ${missing} 后重试"
    fi
    c_grn "依赖安装完成"
  else
    c_grn "全部依赖已就绪，无需安装"
  fi
  # 装完二次确认关键命令真正可用
  for cmd in curl openssl; do
    command -v "${cmd}" >/dev/null 2>&1 || die "${cmd} 安装后仍不可用，请检查软件源"
  done
}
ensure_deps

# ----------------------------- 1. BBR ---------------------------------------
step "开启 BBR + fq（持久化）"
modprobe tcp_bbr 2>/dev/null || true
# 极简系统可能没有 /etc/sysctl.d 目录，先确保存在，避免重定向失败
mkdir -p /etc/sysctl.d
cat > /etc/sysctl.d/99-bbr.conf <<'SYSCTL'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
SYSCTL
# 极简系统可能没有 sysctl 命令（容器常见），全程做存在性判断
if command -v sysctl >/dev/null 2>&1; then
  # 容器/受限内核可能禁止写入运行时参数，失败不致命，配置文件已持久化
  sysctl -p /etc/sysctl.d/99-bbr.conf >/dev/null 2>&1 || c_ylw "运行时生效被限制（容器环境常见），配置已写入持久化文件"
  [ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" = "bbr" ] \
    && c_grn "BBR 已生效" || c_ylw "BBR 运行时未生效（容器/受限内核常见），配置已持久化，真实 VPS 重启即生效"
else
  c_ylw "无 sysctl 命令（极简容器），BBR 配置已写入持久化文件，真实 VPS 上正常生效"
fi

# ----------------------------- 2. Xray --------------------------------------
step "安装/更新 Xray-core"
# 系统依赖已在开头 ensure_deps 统一安装，这里只负责 Xray 本体
HAS_SYSTEMD=0
if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
  HAS_SYSTEMD=1
fi
if [ "${HAS_SYSTEMD}" = "1" ]; then
  # 真实 VPS：官方安装脚本（含 systemd 服务、自动更新）
  bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install \
    | grep -E "installed:|Xray v" || true
else
  # 无 systemd 回退：手动下载官方 zip 部署二进制（容器/WSL/极简系统）
  c_ylw "未检测到 systemd，改用便携方式安装 Xray 二进制"
  ARCH="$(dpkg --print-architecture)"
  case "${ARCH}" in
    amd64) XZIP="Xray-linux-64.zip" ;;
    arm64) XZIP="Xray-linux-arm64-v8a.zip" ;;
    *) die "不支持的架构: ${ARCH}" ;;
  esac
  TMPD="$(mktemp -d)"
  wget -q "https://github.com/XTLS/Xray-core/releases/latest/download/${XZIP}" -O "${TMPD}/x.zip"
  unzip -qo "${TMPD}/x.zip" -d "${TMPD}/x"
  install -m 755 "${TMPD}/x/xray" /usr/local/bin/xray
  mkdir -p /usr/local/etc/xray /usr/local/share/xray
  [ -f "${TMPD}/x/geoip.dat" ] && install -m 644 "${TMPD}/x/geoip.dat" /usr/local/share/xray/
  [ -f "${TMPD}/x/geosite.dat" ] && install -m 644 "${TMPD}/x/geosite.dat" /usr/local/share/xray/
  rm -rf "${TMPD}"
fi
command -v xray >/dev/null 2>&1 || die "Xray 安装失败"
# 不用管道取首行，避免 set -o pipefail 下 head 提前关闭触发 SIGPIPE(141)
XRAY_VER="$(xray version 2>/dev/null | sed -n '1p')"
echo "${XRAY_VER}"

# ----------------------------- 3. 凭据（幂等） -------------------------------
step "生成/复用 Reality 凭据"
UUID=""; PRIV=""; PUB=""; SHORTID=""
if [ -f "${CRED_FILE}" ] && [ "${FORCE_REGEN}" != "1" ]; then
  c_ylw "检测到既有凭据 ${CRED_FILE}，复用（--force-regen 可强制重建）"
  # 只取密钥四件套，避免旧文件里的 PORT/SNI/NODE_NAME 覆盖本次显式参数
  UUID="$(sed -n 's/^UUID=//p' "${CRED_FILE}")"
  PRIV="$(sed -n 's/^PRIV=//p' "${CRED_FILE}")"
  PUB="$(sed -n 's/^PUB=//p' "${CRED_FILE}")"
  SHORTID="$(sed -n 's/^SHORTID=//p' "${CRED_FILE}")"
else
  KEYS="$(xray x25519)"
  PRIV="$(echo "${KEYS}" | grep -i PrivateKey | sed 's/.*: *//;s/ //g')"
  PUB="$(echo "${KEYS}"  | grep -iE 'PublicKey|Password' | sed 's/.*: *//;s/ //g')"
  UUID="$(xray uuid)"
  SHORTID="$(openssl rand -hex 4)"   # 8 位，mihomo 兼容性最好
  c_grn "已生成新密钥对与 UUID"
fi
# 端口/SNI/名称以本次运行为准（即使复用密钥也允许调整）
cat > "${CRED_FILE}" <<EOF
# vps-onekey 凭据，妥善保管，重跑脚本默认复用
UUID=${UUID}
PRIV=${PRIV}
PUB=${PUB}
SHORTID=${SHORTID}
SNI=${SNI}
PORT=${PORT}
NODE_NAME=${NODE_NAME}
EOF
chmod 600 "${CRED_FILE}"
echo "UUID    : ${UUID}"
echo "SHORTID : ${SHORTID}"
echo "SNI     : ${SNI}   端口: ${PORT}"

# ----------------------------- 4. 服务端配置 --------------------------------
step "写入 Xray 配置 ${XRAY_CONF}"
cat > "${XRAY_CONF}" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": ${PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          { "id": "${UUID}", "flow": "${FLOW}" }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${DEST}",
          "xver": 0,
          "serverNames": ["${SNI}"],
          "privateKey": "${PRIV}",
          "shortIds": ["${SHORTID}"],
          "minClientVer": "0.0.0"
        }
      },
      "sniffing": { "enabled": true, "destOverride": ["http","tls","quic"] }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "block" }
  ]
}
EOF

# ----------------------------- 5. 启动验证 ----------------------------------
step "启动 Xray 并设置开机自启"
if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
  # 真实 VPS：systemd 托管
  systemctl daemon-reload
  systemctl enable xray >/dev/null 2>&1 || true
  systemctl restart xray
  sleep 2
  systemctl is-active --quiet xray || die "Xray 未正常运行，查 journalctl -u xray"
else
  # 无 systemd 环境（容器/WSL 等）：直接进程方式拉起，便于验证配置可用
  c_ylw "未检测到 systemd（容器/受限环境），改用直接进程方式启动 Xray"
  pkill xray 2>/dev/null || true
  nohup /usr/local/bin/xray run -config "${XRAY_CONF}" >/var/log/xray-direct.log 2>&1 &
  sleep 2
  # 不依赖 pgrep：用 ps + 端口监听双重确认，procps 缺失也能兜住
  if ! ps -e 2>/dev/null | grep -q '[x]ray'; then die "Xray 启动失败，查 /var/log/xray-direct.log"; fi
fi
# 端口监听确认：优先 ss（iproute2），退回 netstat
if ss -tln 2>/dev/null | grep -q ":${PORT} "; then :; elif netstat -tln 2>/dev/null | grep -q ":${PORT} "; then :; else die "端口 ${PORT} 未监听"; fi
c_grn "Xray 运行中，TCP ${PORT} 已监听"

# ----------------------------- 6. 客户端产物 --------------------------------
step "生成客户端链接与配置片段"
PUBIP="$(curl -fsSL --max-time 10 https://ipinfo.io/ip || echo "YOUR_SERVER_IP")"

VLESS_LINK="vless://${UUID}@${PUBIP}:${PORT}?encryption=none&security=reality&sni=${SNI}&fp=chrome&pbk=${PUB}&sid=${SHORTID}&type=tcp&flow=${FLOW}#${NODE_NAME}"
echo "${VLESS_LINK}" > "${LINK_FILE}"

cat > "${MIHOMO_FILE}" <<EOF
# mihomo-party / Clash Meta 节点片段（粘贴到 proxies: 段，并在代理组引用名称）
# 关键：support-x25519mlkem768 必须在 reality-opts 内部，否则新版 Xray 拒绝握手
  - name: ${NODE_NAME}
    type: vless
    server: ${PUBIP}
    port: ${PORT}
    uuid: ${UUID}
    tls: true
    udp: true
    flow: ${FLOW}
    servername: ${SNI}
    client-fingerprint: chrome
    reality-opts:
      public-key: ${PUB}
      short-id: ${SHORTID}
      support-x25519mlkem768: true
EOF

# ----------------------------- 7. 交付 --------------------------------------
echo
c_grn "==================== 搭建完成 ===================="
cat <<EOF
服务器公网 IP : ${PUBIP}
监听端口      : ${PORT}/TCP
伪装 SNI      : ${SNI}
节点名称      : ${NODE_NAME}
Xray 版本     : ${XRAY_VER}

【vless 链接】Shadowrocket / v2rayN 可直接导入
${VLESS_LINK}

【文件位置】
  凭据         : ${CRED_FILE}
  vless 链接   : ${LINK_FILE}
  mihomo 片段  : ${MIHOMO_FILE}

【必做】云控制台安全组放行入站 TCP ${PORT}，来源 0.0.0.0/0
【可选】本机 mihomo 若把节点连接嵌套进其他代理，在 rules 顶部加：
  - IP-CIDR,${PUBIP}/32,DIRECT,no-resolve
【排错】journalctl -u xray -f   ｜   卸载：./uninstall.sh
【说明】本方案为 IP 直连，无需域名；如需更强隐蔽性可后续套 Cloudflare CDN
EOF
c_grn "=================================================="

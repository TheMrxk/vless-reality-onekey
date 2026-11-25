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
command -v apt >/dev/null 2>&1 || die "当前仅支持 Debian/Ubuntu（apt 系）"
step "系统信息"
. /etc/os-release && echo "OS: ${PRETTY_NAME}  内核: $(uname -r)"
mkdir -p "${WORKDIR}"

# ----------------------------- 1. BBR ---------------------------------------
step "开启 BBR + fq（持久化）"
modprobe tcp_bbr 2>/dev/null || true
cat > /etc/sysctl.d/99-bbr.conf <<'SYSCTL'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
SYSCTL
sysctl -p /etc/sysctl.d/99-bbr.conf >/dev/null
[ "$(sysctl -n net.ipv4.tcp_congestion_control)" = "bbr" ] \
  && c_grn "BBR 已生效" || c_ylw "BBR 未生效（内核过老？），继续安装"

# ----------------------------- 2. Xray --------------------------------------
step "安装/更新 Xray-core（官方脚本）"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl openssl ca-certificates >/dev/null
bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install \
  | grep -E "installed:|Xray v" || true
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
systemctl daemon-reload
systemctl enable xray >/dev/null 2>&1 || true
systemctl restart xray
sleep 2
systemctl is-active --quiet xray || die "Xray 未正常运行，查 journalctl -u xray"
ss -tlnp | grep ":${PORT} " >/dev/null || die "端口 ${PORT} 未监听"
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

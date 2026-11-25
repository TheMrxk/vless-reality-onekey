#!/usr/bin/env bash
###############################################################################
# vps-onekey / uninstall.sh
# 卸载由 install.sh 搭建的 Xray 代理
#   ./uninstall.sh          停用并移除 Xray，保留 /etc/vps-onekey 凭据备份
#   ./uninstall.sh --purge  彻底清理，连凭据/配置/BBR 自定义项一起删除
###############################################################################
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "请用 root 运行"; exit 1; }

echo "── 停止并禁用 Xray ──"
systemctl stop xray 2>/dev/null || true
systemctl disable xray 2>/dev/null || true

echo "── 移除 Xray 程序（官方卸载）──"
if command -v xray >/dev/null 2>&1; then
  bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove --purge 2>/dev/null \
    || echo "官方卸载脚本执行异常，可手动 rm -rf /usr/local/bin/xray /usr/local/etc/xray"
else
  echo "未检测到 xray，跳过"
fi

if [ "${1:-}" = "--purge" ]; then
  echo "── purge：删除凭据与 BBR 自定义配置 ──"
  rm -rf /etc/vps-onekey
  rm -f /etc/sysctl.d/99-bbr.conf
  sysctl -p /etc/sysctl.conf >/dev/null 2>&1 || true
  echo "已彻底清理"
else
  echo "已停用移除；凭据保留在 /etc/vps-onekey/cred.env（加 --purge 可彻底删除）"
fi
echo "完成"

# vps-onekey

一键把干净的 Debian/Ubuntu VPS 部署成 **VLESS + Reality + Vision** 代理节点，输出可被
mihomo（Clash Meta）/ Shadowrocket / v2rayN 直接导入的 `vless://` 链接。

纯 IP 直连方案，**无需自备域名、不依赖 UDP**，默认端口特意选 543 以规避部分软路由对 443 的 SNI 劫持。

> ⚠️ **免责声明**：本项目仅供学习网络协议与系统运维之用。请确保你的使用符合所在国家/地区的法律法规及
> VPS 服务商条款。作者不对任何滥用行为及其后果负责，使用者自行承担全部风险。

## 特性

- 交互式问答（带默认值，回车即用）+ 命令行参数 + 配置文件，三种用法兼顾新手与自动化
- 自动开启并持久化 **BBR + fq**
- 官方脚本安装 Xray，密钥/UUID/shortId 自动生成且**幂等**（重跑不重置）
- 服务端设 `minClientVer=0.0.0`，客户端片段内置 `support-x25519mlkem768`，兼容新版 Xray 与 mihomo
- 内置输入校验、失败回滚提示与独立卸载脚本

## 环境要求

- 服务端：Debian 11/12 或 Ubuntu 22.04/24.04，root 权限
- 云安全组放行入站 **TCP 端口**（默认 543），来源 `0.0.0.0/0`
- 客户端：支持 VLESS + Reality 的内核（mihomo ≥ 1.18、Shadowrocket、v2rayN 等）

## 快速开始

```bash
# 上传后登录 VPS
chmod +x install.sh
./install.sh
```

### 用法一：交互式（默认）

直接运行，逐项确认端口、伪装域名、节点名，每项括号内都是默认值，回车采用：

```
监听端口 [543]：
伪装域名 SNI [www.apple.com]：
节点显示名 [Reality-Node]：
```

### 用法二：命令行参数（非交互 / CI）

```bash
./install.sh --port 443 --sni www.microsoft.com --name mynode
./install.sh --force-regen          # 强制重新生成全部密钥
./install.sh --help                 # 查看全部参数
```

| 参数 | 说明 | 默认值 |
|---|---|---|
| `--port` | 监听 TCP 端口（1-65535） | `543` |
| `--sni` | 伪装域名，需支持 TLS1.3+H2 的真实大站 | `www.apple.com` |
| `--name` | 节点显示名 | `Reality-Node` |
| `--config` | 从 KEY=value 配置文件读取 | 无 |
| `--force-regen` | 强制重建密钥（旧客户端失效） | 关 |

### 用法三：配置文件

```bash
cp config.example.txt my.conf
# 编辑 my.conf
./install.sh --config my.conf
```

## 参数怎么选（重要）

- **端口 PORT**：默认 543。如果你的网络环境只对 443 做 SNI 检测，543 这类非标准端口往往能绕过；
  若云厂商或网络只放行 443，再用 `--port 443`。
- **伪装域名 SNI**：必须是真实可访问、支持 TLS1.3 与 H2 的大站（Apple / Microsoft / Google 下载域等），
  且服务器能回源到它。换 SNI 不影响密钥，可随时重跑脚本调整。
- **域名**：本方案不需要你拥有任何域名。只有在追求更强隐蔽性、打算套 Cloudflare CDN 时才需要自备域名，
  那是另一套架构，不在本脚本范围。

## 客户端接入

脚本结束会打印并保存到 `/etc/vps-onekey/`：

- `node-link.txt`：`vless://` 链接，Shadowrocket / v2rayN 直接导入，或用 `make_qrcode.py` 生成二维码扫码
- `mihomo-node.yaml`：mihomo-party / Clash Meta 节点片段，粘到 `proxies:` 段并在代理组引用

mihomo 若把到该服务器的连接又嵌套进其他代理，在 `rules:` 顶部加一条：

```yaml
- IP-CIDR,你的服务器IP/32,DIRECT,no-resolve
```

### 生成二维码（本机，可选）

```bash
python3 -m venv .venv && . .venv/bin/activate
pip install "qrcode[pil]"
./make_qrcode.py node-link.txt node.png
```

## 卸载

```bash
./uninstall.sh           # 停用移除 Xray，保留 /etc/vps-onekey 凭据
./uninstall.sh --purge   # 连凭据与 BBR 自定义配置一起清除
```

## 设计中固化的真实排错经验

1. **SSH 被本地代理劫持** → 客户端对 VPS IP 加 DIRECT 规则
2. **外网 UDP 被封** → 部分软路由/运营商封锁 UDP，Hysteria2 等失效，故选纯 TCP 的 Reality
3. **443 被 SNI 劫持** → 软路由对 443 按 SNI 分流，握手到不了服务器，默认改用 543
4. **新版 Xray 后量子校验** → Xray-core ≥ 26.7.11 默认要求 X25519MLKEM768，mihomo 必须在
   `reality-opts` **内部**加 `support-x25519mlkem768: true`，服务端同时设 `minClientVer:"0.0.0"`

## 文件说明

| 文件 | 作用 |
|---|---|
| `install.sh` | 服务端一键安装（幂等） |
| `uninstall.sh` | 卸载 / 彻底清理 |
| `make_qrcode.py` | 节点链接转二维码 |
| `config.example.txt` | 配置文件模板 |
| `.gitignore` | 防止凭据误提交 |

## 安全提示

- `/etc/vps-onekey/cred.env` 权限 600，含 X25519 私钥，切勿外传或提交到任何仓库
- 定期 `apt update && apt upgrade` 并重启 Xray 保持内核与组件更新
- 若在公开 Issue 求助，请先打码服务器 IP、UUID 与公钥

## 开源协议

本项目基于 **GPL-3.0-only** 协议开源，详见 [LICENSE](LICENSE)。你可以自由使用、修改与再分发，
但需保留版权与免责声明、以相同协议开源衍生作品。作者保留署名权（Copyright © 2026 TheMrxk）。

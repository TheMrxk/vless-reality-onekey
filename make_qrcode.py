#!/usr/bin/env python3
"""
vps-onekey / make_qrcode.py
把 vless:// 节点链接生成二维码图片，方便 Shadowrocket 手机扫码导入。

依赖（本机一次性安装，建议用虚拟环境）：
  python3 -m venv .venv && . .venv/bin/activate
  pip install "qrcode[pil]"

用法：
  ./make_qrcode.py <vless链接文件或链接字符串> [输出png路径]
示例：
  ./make_qrcode.py node-link.txt 节点二维码.png
"""
import sys, os
import qrcode

def main():
    if len(sys.argv) < 2:
        sys.exit("用法: make_qrcode.py <链接或文件> [输出.png]")
    src = sys.argv[1]
    link = open(src, encoding="utf-8").read().strip() if os.path.isfile(src) else src.strip()
    if not link.startswith("vless://"):
        sys.exit("错误：内容不是 vless:// 链接")
    out = sys.argv[2] if len(sys.argv) > 2 else "node-qrcode.png"
    qr = qrcode.QRCode(error_correction=qrcode.constants.ERROR_CORRECT_M, box_size=12, border=3)
    qr.add_data(link); qr.make(fit=True)
    qr.make_image(fill_color="black", back_color="white").save(out)
    print(f"已生成二维码: {os.path.abspath(out)}")

if __name__ == "__main__":
    main()

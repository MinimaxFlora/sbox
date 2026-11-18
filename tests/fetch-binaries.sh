#!/usr/bin/env bash
# tests/fetch-binaries.sh — 下载测试所需的 sing-box 与 mihomo 二进制到 .bin/
#
# 环境变量：
#   SINGBOX_VERSION  固定 sing-box 版本（默认最新稳定版）
#   MIHOMO_VERSION   固定 mihomo 版本（默认最新版）

set -Eeuo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
BIN_DIR=${BIN_DIR:-$ROOT/.bin}
mkdir -p "$BIN_DIR"

arch=$(uname -m)
case $arch in
    x86_64) sb_arch=amd64; mh_arch=amd64 ;;
    aarch64 | arm64) sb_arch=arm64; mh_arch=arm64 ;;
    *) echo "不支持的测试架构：$arch"; exit 1 ;;
esac

api=https://api.github.com

# ── sing-box ──
sb_ver=${SINGBOX_VERSION:-}
if [[ -z $sb_ver ]]; then
    sb_ver=$(curl -fsSL -m 20 "$api/repos/SagerNet/sing-box/releases/latest" \
        | grep -m1 -oE '"tag_name": *"[^"]+"' | sed -E 's/.*"([^"]+)"$/\1/')
fi
[[ $sb_ver == v* ]] || sb_ver="v$sb_ver"
sb_file="sing-box-${sb_ver#v}-linux-${sb_arch}.tar.gz"
echo "sing-box: $sb_ver"
curl -fsSL -m 180 -o "/tmp/$sb_file" \
    "https://github.com/SagerNet/sing-box/releases/download/$sb_ver/$sb_file"
tmpd=$(mktemp -d)
tar -xzf "/tmp/$sb_file" -C "$tmpd"
find "$tmpd" -type f -name sing-box -exec cp {} "$BIN_DIR/sing-box" \;
chmod +x "$BIN_DIR/sing-box"
rm -rf "$tmpd" "/tmp/$sb_file"
"$BIN_DIR/sing-box" version | head -1

# ── mihomo ──
mh_ver=${MIHOMO_VERSION:-}
if [[ -z $mh_ver ]]; then
    mh_ver=$(curl -fsSL -m 20 "$api/repos/MetaCubeX/mihomo/releases/latest" \
        | grep -m1 -oE '"tag_name": *"[^"]+"' | sed -E 's/.*"([^"]+)"$/\1/')
fi
[[ $mh_ver == v* ]] || mh_ver="v$mh_ver"
mh_file="mihomo-linux-${mh_arch}-${mh_ver}.gz"
echo "mihomo: $mh_ver"
curl -fsSL -m 180 -o "/tmp/mihomo.gz" \
    "https://github.com/MetaCubeX/mihomo/releases/download/$mh_ver/$mh_file"
gunzip -f -c "/tmp/mihomo.gz" >"$BIN_DIR/mihomo"
chmod +x "$BIN_DIR/mihomo"
rm -f "/tmp/mihomo.gz"
"$BIN_DIR/mihomo" -v 2>&1 | head -1 || true

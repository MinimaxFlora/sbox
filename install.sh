#!/usr/bin/env bash
# install.sh — sbox 引导安装脚本
#
# 在线安装（推荐）：
#   curl -fsSL https://raw.githubusercontent.com/MinimaxFlora/sbox/main/install.sh | bash
#
# 指定通道 / 地址 / 订阅端口：
#   bash install.sh --channel testing --addr 1.2.3.4 --sub-port 2087
#
# 本地开发安装：
#   bash install.sh --local /path/to/sbox

set -Eeuo pipefail

SBOX_ROOT=${SBOX_ROOT:-/usr/local/lib/sbox}
SBOX_BIN=${SBOX_BIN:-/usr/local/bin/sbox}
SBOX_SOURCE_URL=${SBOX_SOURCE_URL:-https://github.com/MinimaxFlora/sbox}
BRANCH=main
CHANNEL=stable
EXTRA_ARGS=()

_bold=$'\033[1m'
_reset=$'\033[0m'
_info() { printf '  · %s\n' "$*"; }
_die() { printf '  ✗ %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
用法：install.sh [选项]

  --channel <stable|testing>   sing-box 版本通道（默认 stable）
  --addr <地址>                节点/订阅使用的对外地址（默认自动探测）
  --sub-port <端口>            订阅服务端口（默认 2087）
  --no-sub                     不启用订阅服务
  --branch <分支>              拉取脚本的分支（默认 main）
  --source-url <URL>           脚本仓库地址
  --local <目录>               使用本地代码目录（开发用）
  --yes                        跳过确认
EOF
}

LOCAL_DIR=''
while [[ $# -gt 0 ]]; do
    case $1 in
        --channel) CHANNEL=${2:-stable}; shift 2 ;;
        --addr) EXTRA_ARGS+=(--addr "${2:-}"); shift 2 ;;
        --sub-port) EXTRA_ARGS+=(--sub-port "${2:-}"); shift 2 ;;
        --sub-bind) EXTRA_ARGS+=(--sub-bind "${2:-}"); shift 2 ;;
        --no-sub) EXTRA_ARGS+=(--no-sub 1); shift ;;
        --reality-sni) EXTRA_ARGS+=(--reality-sni "${2:-}"); shift 2 ;;
        --branch) BRANCH=${2:-main}; shift 2 ;;
        --source-url) SBOX_SOURCE_URL=${2:-}; shift 2 ;;
        --local) LOCAL_DIR=${2:-}; shift 2 ;;
        --yes | -y) EXTRA_ARGS+=(--yes); shift ;;
        -h | --help) usage; exit 0 ;;
        *) _die "未知参数：$1" ;;
    esac
done

[[ ${EUID:-$(id -u)} -eq 0 ]] || _die '需要 root 权限，请使用 sudo 运行'

printf '\n  %ssbox 安装程序%s\n' "$_bold" "$_reset"
_info "代码目录：$SBOX_ROOT"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

if [[ -n $LOCAL_DIR ]]; then
    _info "使用本地代码：$LOCAL_DIR"
    [[ -f $LOCAL_DIR/sbox.sh ]] || _die "本地目录无效：$LOCAL_DIR"
    SRC=$LOCAL_DIR
else
    _info "下载代码包：${SBOX_SOURCE_URL}（分支 ${BRANCH}）"
    mkdir -p "$TMP/pkg"
    ok=0
    # Gitea: /archive/<ref>.tar.gz；GitHub: /archive/refs/heads/<ref>.tar.gz
    for url in "${SBOX_SOURCE_URL}/archive/${BRANCH}.tar.gz" \
               "${SBOX_SOURCE_URL}/archive/refs/heads/${BRANCH}.tar.gz"; do
        for i in 1 2; do
            if curl -fsSL --connect-timeout 10 --max-time 180 \
                -o "$TMP/pkg/src.tar.gz" "$url"; then
                ok=1
                break 2
            fi
            _info "重试下载（${i}/2）：$url"
            sleep 2
        done
    done
    ((ok)) || _die "代码包下载失败（${SBOX_SOURCE_URL}）"
    tar -xzf "$TMP/pkg/src.tar.gz" -C "$TMP/pkg" || _die '代码包解压失败'
    SRC=$(find "$TMP/pkg" -maxdepth 1 -mindepth 1 -type d | head -1)
    [[ -n $SRC ]] || _die '代码包内容异常'
fi

mkdir -p "$SBOX_ROOT"
rm -rf "$SBOX_ROOT/src"
cp -a "$SRC/src" "$SBOX_ROOT/"
cp -f "$SRC/sbox.sh" "$SBOX_ROOT/sbox.sh"
cp -f "$SRC/VERSION" "$SBOX_ROOT/VERSION" 2>/dev/null || printf '0.0.0\n' >"$SBOX_ROOT/VERSION"
chmod 755 "$SBOX_ROOT/sbox.sh"

mkdir -p "$(dirname "$SBOX_BIN")"
ln -sfn "$SBOX_ROOT/sbox.sh" "$SBOX_BIN"
_info "已安装 sbox 命令：$SBOX_BIN"

exec "$SBOX_ROOT/sbox.sh" install --channel "$CHANNEL" "${EXTRA_ARGS[@]}"

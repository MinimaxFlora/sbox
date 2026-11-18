#!/usr/bin/env bash
# sbox.sh — sbox 主入口（Sing-Box 一键管理脚本）
# 用法：sbox [命令] [参数]；不带参数进入交互菜单。

set -Eeuo pipefail

_sbox_self=$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")
SBOX_ROOT=${SBOX_ROOT:-$(cd "$(dirname "$_sbox_self")" && pwd)}

# shellcheck source=src/lib/common.sh
source "$SBOX_ROOT/src/lib/common.sh"
# shellcheck source=src/lib/ui.sh
source "$SBOX_ROOT/src/lib/ui.sh"
# shellcheck source=src/lib/sys.sh
source "$SBOX_ROOT/src/lib/sys.sh"
# shellcheck source=src/lib/conf.sh
source "$SBOX_ROOT/src/lib/conf.sh"
# shellcheck source=src/lib/version.sh
source "$SBOX_ROOT/src/lib/version.sh"
# shellcheck source=src/lib/tls.sh
source "$SBOX_ROOT/src/lib/tls.sh"
# shellcheck source=src/lib/node.sh
source "$SBOX_ROOT/src/lib/node.sh"
# shellcheck source=src/lib/render.sh
source "$SBOX_ROOT/src/lib/render.sh"
# shellcheck source=src/lib/link.sh
source "$SBOX_ROOT/src/lib/link.sh"
# shellcheck source=src/lib/sub.sh
source "$SBOX_ROOT/src/lib/sub.sh"
# shellcheck source=src/lib/service.sh
source "$SBOX_ROOT/src/lib/service.sh"
# shellcheck source=src/lib/setup.sh
source "$SBOX_ROOT/src/lib/setup.sh"
# shellcheck source=src/lib/menu.sh
source "$SBOX_ROOT/src/lib/menu.sh"
# shellcheck source=src/lib/cli.sh
source "$SBOX_ROOT/src/lib/cli.sh"

trap 'sbox_err_trap $? $LINENO "$BASH_COMMAND"' ERR

# 所有命令（除只读命令）都需要 root 权限（写 /etc、管理 systemd）
case ${1:-menu} in
    help | -h | --help | version | internal)
        ;;
    *)
        need_root
        ;;
esac

# 载入全局配置（只读命令也需要）
if [[ -r $SBOX_CONF ]]; then
    conf_load
fi

main_dispatch "$@"

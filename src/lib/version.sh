# shellcheck shell=bash
# version.sh — sing-box 二进制版本管理：稳定版 / 测试版 / 指定版本

if [[ -n ${SBOX_VERSION_SH:-} ]]; then return 0; fi
readonly SBOX_VERSION_SH=1

readonly SB_LINK=${SB_LINK:-/usr/local/bin/sing-box}

sbox_singbox_path() { printf '%s' "$SB_LINK"; }

sb_current_bin() {
    local p
    p=$(readlink -f "$SB_LINK" 2>/dev/null || true)
    [[ -x ${p:-} ]] && printf '%s' "$p"
}

sb_current_version() {
    local bin
    bin=$(sb_current_bin) || return 1
    [[ -x $bin ]] || return 1
    "$bin" version 2>/dev/null | awk '/^sing-box version/ {print $3; exit}'
}

sb_current_tag() {
    local bin ver
    bin=$(sb_current_bin) || return 1
    ver=${bin#"$SBOX_VERSIONS_DIR"/}
    ver=${ver%%/*}
    [[ -n $ver ]] && printf '%s' "$ver"
}

sb_channel() { # stable / testing / <tag>
    local ch=''
    [[ -r $SBOX_STATE_FILE ]] && ch=$(sed -n 's/^channel=//p' "$SBOX_STATE_FILE" | head -1)
    [[ -n $ch ]] && printf '%s' "$ch" || printf 'unknown'
}

sb_set_state() { # sb_set_state <key> <value>
    local key=$1 val=$2
    mkdir -p "$SBOX_ETC"
    touch "$SBOX_STATE_FILE"
    if grep -q "^$key=" "$SBOX_STATE_FILE" 2>/dev/null; then
        sed -i "s|^$key=.*|$key=$val|" "$SBOX_STATE_FILE"
    else
        printf '%s=%s\n' "$key" "$val" >>"$SBOX_STATE_FILE"
    fi
    chmod 600 "$SBOX_STATE_FILE"
}

sb_asset_name() { # sb_asset_name <tag> → sing-box-1.14.4-linux-amd64.tar.gz
    local tag=$1 ver arch
    ver=${tag#v}
    arch=$(sys_arch)
    printf 'sing-box-%s-linux-%s.tar.gz' "$ver" "$arch"
}

# 查询 GitHub release 列表并挑出目标 tag
# sb_remote_tag <stable|testing|版本号>
sb_remote_tag() {
    local channel=${1:-stable}
    local json tag
    case $channel in
        stable | latest)
            json=$(curl -fsS -m 20 "$SBOX_GH_API/repos/$SBOX_GH_REPO/releases/latest" 2>/dev/null) || return 1
            tag=$(printf '%s' "$json" | grep -m1 -oE '"tag_name": *"[^"]+"' \
                | sed -E 's/.*"([^"]+)"$/\1/')
            ;;
        testing | beta | alpha)
            json=$(curl -fsS -m 20 "$SBOX_GH_API/repos/$SBOX_GH_REPO/releases?per_page=30" 2>/dev/null) || return 1
            if command -v python3 >/dev/null 2>&1; then
                tag=$(printf '%s' "$json" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except ValueError:
    sys.exit(1)
for rel in data:
    if rel.get("prerelease") and not rel.get("draft"):
        print(rel["tag_name"]); break
' 2>/dev/null)
            fi
            # 无 python3 时用 awk 解析（tag_name 位于 prerelease 之前）
            if [[ -z $tag ]]; then
                tag=$(printf '%s' "$json" | awk -F'"' '
                    /"tag_name"/ { t = $4 }
                    /"prerelease": *true/ { if (t != "") { print t; exit } }')
            fi
            ;;
        *)
            printf '%s' "$channel"
            return 0
            ;;
    esac
    [[ -n $tag ]] || return 1
    printf '%s' "$tag"
}

# 校验下载的 release 包是否包含目标二进制
sb_extract_binary() { # sb_extract_binary <tar> <tag> <目标路径>
    local tar_file=$1 tag=$2 dest=$3 ver arch tmpdir inner
    ver=${tag#v}
    arch=$(sys_arch)
    tmpdir=$(mktemp -d)
    if ! tar -xzf "$tar_file" -C "$tmpdir" 2>/dev/null; then
        rm -rf "$tmpdir"
        return 1
    fi
    inner=$(find "$tmpdir" -type f -name sing-box -perm -u+x 2>/dev/null | head -1)
    if [[ -z $inner ]]; then
        inner=$(find "$tmpdir" -type f -name sing-box 2>/dev/null | head -1)
    fi
    if [[ -z $inner ]]; then
        rm -rf "$tmpdir"
        return 1
    fi
    mkdir -p "$(dirname "$dest")"
    install -m 755 "$inner" "$dest"
    rm -rf "$tmpdir"
}

# sb_install_version <tag>：下载并安装到 versions/<tag>/
sb_install_version() {
    local tag=$1 asset tmp ver
    ver=${tag#v}
    asset=$(sb_asset_name "$tag")
    tmp=$(mktemp)
    info "下载 sing-box ${tag}（${asset}）"
    if ! sys_download_gh "SagerNet/sing-box/releases/download/${tag}/${asset}" "$tmp"; then
        rm -f "$tmp"
        die "sing-box ${tag} 下载失败，可设置 SBOX_GH_MIRROR 使用镜像"
    fi
    if ! sb_extract_binary "$tmp" "$tag" "$SBOX_VERSIONS_DIR/$tag/sing-box"; then
        rm -f "$tmp"
        die "sing-box 安装包解析失败：${asset}"
    fi
    rm -f "$tmp"
    if ! "$SBOX_VERSIONS_DIR/$tag/sing-box" version >/dev/null 2>&1; then
        rm -rf "${SBOX_VERSIONS_DIR:?}/$tag"
        die "sing-box ${tag} 在当前架构（$(sys_arch)）无法运行"
    fi
    chmod 755 "$SBOX_VERSIONS_DIR/$tag"
    ok "sing-box ${tag} 已安装"
}

# sb_link_version <tag>：切换 /usr/local/bin/sing-box 指向
sb_link_version() {
    local tag=$1 bin="$SBOX_VERSIONS_DIR/$1/sing-box"
    [[ -x $bin ]] || die "版本 ${tag} 未安装"
    mkdir -p "$(dirname "$SB_LINK")"
    ln -sfn "$bin" "$SB_LINK"
    ok "sing-box 已切换至 ${tag}"
}

# sb_apply_version <tag> [channel]：校验配置 → 切换 → 重启
sb_apply_version() {
    local tag=$1 channel=${2:-custom} bin cfg rc=0
    [[ -x $SBOX_VERSIONS_DIR/$tag/sing-box ]] || sb_install_version "$tag"
    bin="$SBOX_VERSIONS_DIR/$tag/sing-box"

    if [[ -s $SBOX_SERVER_JSON ]]; then
        if ! out=$("$bin" check -c "$SBOX_SERVER_JSON" 2>&1); then
            printf '%s\n' "$out" >&2
            die "当前服务端配置与 sing-box ${tag} 不兼容，已取消切换"
        fi
    fi

    sb_link_version "$tag"
    sb_set_state channel "$channel"
    sb_set_state version "$tag"

    if systemctl is-active --quiet "$SBOX_SINGBOX_SERVICE" 2>/dev/null; then
        systemctl restart "$SBOX_SINGBOX_SERVICE" || rc=$?
        sleep 1
        if ((rc == 0)) && systemctl is-active --quiet "$SBOX_SINGBOX_SERVICE"; then
            ok "服务已用 ${tag} 重启"
        else
            warn "服务重启异常，请查看：journalctl -u ${SBOX_SINGBOX_SERVICE} -n 50"
        fi
    fi
}

sb_installed_list() {
    local d
    for d in "$SBOX_VERSIONS_DIR"/*/; do
        [[ -d $d ]] || continue
        basename "$d"
    done | sort -V
}

sb_version_report() {
    local cur tag ch
    tag=$(sb_current_tag || printf '未安装')
    cur=$(sb_current_version || printf '—')
    ch=$(sb_channel)
    ui_kv '脚本版本' "v$(sbox_script_version)"
    ui_kv 'sing-box' "${cur}  ${C_GREY}(通道 ${ch}${tag:+, 目录 ${tag}})${C_RESET}"
    ui_kv '二进制' "$(sb_current_bin || printf '—')"
    local tags
    tags=$(sb_installed_list | tr '\n' ' ')
    [[ -n $tags ]] && ui_kv '已安装' "$tags"
    return 0
}

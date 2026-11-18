# shellcheck shell=bash
# link.sh — 节点分享链接（vless / hysteria2 / anytls / tuic）与二维码

if [[ -n ${SBOX_LINK_SH:-} ]]; then return 0; fi
readonly SBOX_LINK_SH=1

# 客户端是否需要跳过证书校验（自签证书为 true）
_link_insecure() {
    local mode
    mode=$(node_meta "$1" tls_mode)
    [[ $mode == selfsigned ]]
}

# link_for_node <name> → 标准分享链接（sing-box / mihomo / v2rayN 通用）
link_for_node() {
    local name=$1 type server port sni pw uuid tag
    node_exists "$name" || die "节点 ${name} 不存在"
    type=$(node_type "$name")
    server=$(node_addr "$name")
    port=$(node_meta "$name" port)
    sni=$(node_meta "$name" sni)
    tag=$(urlencode "$name")

    case $type in
        vless)
            uuid=$(node_meta "$name" uuid)
            printf 'vless://%s@%s:%s?encryption=none&flow=%s&security=reality&sni=%s&fp=%s&pbk=%s&sid=%s&type=tcp&headerType=none#%s' \
                "$(urlencode "$uuid")" "$(fmt_host "$server")" "$port" \
                "$(urlencode "$(node_meta "$name" flow 'xtls-rprx-vision')")" \
                "$(urlencode "$sni")" \
                "$(urlencode "$(node_meta "$name" fingerprint chrome)")" \
                "$(urlencode "$(node_meta "$name" reality_public)")" \
                "$(urlencode "$(node_meta "$name" short_id)")" "$tag"
            ;;
        hysteria2)
            pw=$(node_meta "$name" password)
            local insecure='0' obfs_q=''
            _link_insecure "$name" && insecure='1'
            local obfs obfspw
            obfs=$(node_meta "$name" obfs)
            obfspw=$(node_meta "$name" obfs_password)
            [[ -n $obfs ]] && obfs_q="&obfs=$(urlencode "$obfs")&obfs-password=$(urlencode "$obfspw")"
            printf 'hysteria2://%s@%s:%s/?sni=%s&alpn=h3&insecure=%s%s#%s' \
                "$(urlencode "$pw")" "$(fmt_host "$server")" "$port" \
                "$(urlencode "$sni")" "$insecure" "$obfs_q" "$tag"
            ;;
        anytls)
            pw=$(node_meta "$name" password)
            local insecure='0'
            _link_insecure "$name" && insecure='1'
            printf 'anytls://%s@%s:%s/?sni=%s&alpn=h2&insecure=%s#%s' \
                "$(urlencode "$pw")" "$(fmt_host "$server")" "$port" \
                "$(urlencode "$sni")" "$insecure" "$tag"
            ;;
        tuic)
            uuid=$(node_meta "$name" uuid)
            pw=$(node_meta "$name" password)
            local insecure='0'
            _link_insecure "$name" && insecure='1'
            printf 'tuic://%s:%s@%s:%s/?sni=%s&alpn=h3&congestion_control=%s&udp_relay_mode=%s&allow_insecure=%s#%s' \
                "$(urlencode "$uuid")" "$(urlencode "$pw")" "$(fmt_host "$server")" "$port" \
                "$(urlencode "$sni")" \
                "$(urlencode "$(node_meta "$name" congestion bbr)")" \
                "$(urlencode "$(node_meta "$name" udp_relay_mode native)")" \
                "$insecure" "$tag"
            ;;
        *) die "未知节点类型：$type" ;;
    esac
}

# 所有节点链接（每行一条）
link_all() {
    local n
    for n in $(node_names); do
        link_for_node "$n"
        printf '\n'
    done
}

# 订阅用的 base64 链接列表
link_all_b64() {
    link_all | b64
}

# 是否安装了二维码工具
link_has_qr() { command -v qrencode >/dev/null 2>&1; }

# 安装 qrencode（可选，失败不阻塞）
link_ensure_qr() {
    link_has_qr && return 0
    info "安装二维码工具 qrencode（可选）"
    case $(sys_pkg_manager) in
        apt) sys_install_pkgs qrencode ;;
        apk) sys_install_pkgs libqrencode-tools || sys_install_pkgs qrencode ;;
        dnf | yum) sys_install_pkgs qrencode ;;
        pacman) sys_install_pkgs qrencode ;;
        *) return 1 ;;
    esac
    link_has_qr
}

link_qr() { # link_qr <链接> [终端|png]
    local url=$1 out=${2:-terminal}
    link_ensure_qr || { warn "qrencode 不可用，仅显示链接"; return 1; }
    case $out in
        png) local f; f=$(mktemp --suffix=.png 2>/dev/null || mktemp); qrencode -o "$f" -s 8 -m 2 "$url" && printf '%s' "$f" ;;
        terminal | *) qrencode -t ANSIUTF8 -m 2 "$url" ;;
    esac
}

# link_show <name>：展示单个节点的完整信息
link_show() {
    local name=$1 url type
    node_exists "$name" || die "节点 ${name} 不存在"
    type=$(node_proto_label "$(node_type "$name")")
    url=$(link_for_node "$name")

    printf '\n'
    ui_kv '节点' "$name"
    ui_kv '协议' "$type"
    ui_kv '地址' "$(fmt_host "$(node_addr "$name")"):$(node_meta "$name" port)/$(node_port_proto "$name")"
    ui_kv 'SNI' "$(node_meta "$name" sni)"
    ui_kv '证书' "$(tls_summary "$name")"
    printf '\n  %s分享链接%s\n' "$C_BOLD" "$C_RESET"
    printf '  %s\n' "$url"
    printf '\n'
    link_qr "$url" terminal || true
}

# shellcheck shell=bash
# cli.sh — 命令行接口与调度

if [[ -n ${SBOX_CLI_SH:-} ]]; then return 0; fi
readonly SBOX_CLI_SH=1

declare -A ARGS=()
POSITIONAL=()

parse_flags() {
    ARGS=()
    POSITIONAL=()
    while [[ $# -gt 0 ]]; do
        case $1 in
            -y | --yes) SBOX_ASSUME_YES=1; shift ;;
            -h | --help) ARGS[help]=1; shift ;;
            --*)
                local key=${1#--}
                if [[ $key == *=* ]]; then
                    ARGS[${key%%=*}]=${key#*=}
                    shift
                elif [[ $# -ge 2 && ${2} != --* ]]; then
                    ARGS[$key]=$2
                    shift 2
                else
                    ARGS[$key]=1
                    shift
                fi
                ;;
            *) POSITIONAL+=("$1"); shift ;;
        esac
    done
}

# ───────────── 状态 ─────────────
cmd_status() {
    local os arch init kernel
    os=$(sys_os_name)
    arch=$(sys_arch)
    init=$(sys_init)
    kernel=$(uname -r)

    ui_title '系统'
    ui_kv '系统' "$os"
    ui_kv '架构' "${arch}  (${init}, 内核 ${kernel})"
    ui_kv '加速' "$(sys_bbr)"

    printf '\n'
    ui_title '服务'
    service_status_summary
    ui_kv '版本' "$(sb_current_version 2>/dev/null || echo '未安装')  ${C_GREY}$(sb_channel)${C_RESET}"
    if service_active_singbox; then
        local listen
        listen=$(ss -tlnup 2>/dev/null | awk '/sing-box/ {print $5}' | wc -l)
        ui_kv '监听' "${listen} 个套接字"
    fi

    printf '\n'
    ui_title '节点'
    node_table

    printf '\n'
    ui_title '订阅'
    if [[ $(node_count) -gt 0 ]]; then
        ui_kv 'sing-box' "$(sub_url singbox)"
        ui_kv 'mihomo' "$(sub_url mihomo)"
        ui_kv 'v2rayN' "$(sub_url v2ray)"
    else
        ui_note '尚未添加节点'
    fi
    printf '\n'
}

cmd_node_list() {
    local name=${1:-}
    if [[ -n $name ]]; then
        link_show "$name"
        return 0
    fi
    node_table
}

cmd_node_show() { link_show "$1"; }

# ───────────── 版本 ─────────────
cmd_version() {
    local sub=${1:-}
    case $sub in
        '' | report | show) ui_title '版本'; sb_version_report ;;
        list) sb_installed_list ;;
        switch)
            local target=${2:-}
            [[ -n $target ]] || die "用法：sbox version switch <stable|testing|版本号>"
            cmd_version_switch "$target"
            ;;
        *) die "未知子命令：version $sub" ;;
    esac
}

cmd_version_switch() {
    local target=$1 tag
    case $target in
        stable | latest) info '查询最新稳定版…'; tag=$(sb_remote_tag stable) || die '查询失败（GitHub API 不可达）' ;;
        testing | beta | alpha) info '查询最新测试版…'; tag=$(sb_remote_tag testing) || die '查询失败（GitHub API 不可达）' ;;
        *) tag=$target; [[ $tag == v* ]] || tag="v$tag" ;;
    esac
    [[ -n $tag ]] || die '未找到可用版本'
    printf '\n'
    ui_kv '目标版本' "$tag"
    if [[ -x $SBOX_VERSIONS_DIR/$tag/sing-box ]]; then
        info "该版本已安装，直接切换"
    else
        sb_install_version "$tag"
    fi
    sb_apply_version "$tag" "$target"
    printf '\n'
    sb_version_report
}

# ───────────── 订阅 ─────────────
cmd_sub() {
    local sub=${1:-show}
    case $sub in
        show | url) sub_show ;;
        files) sub_export_files; ok "订阅文件已生成：$SBOX_SUB_DIR" ;;
        port)
            local p=${2:-}
            valid_port "$p" || die '端口不合法'
            sys_firewall_close "$(sub_port)" tcp
            conf_set SUB_PORT "$p"
            sys_firewall_open "$p" tcp
            sub_apply_settings
            service_restart_sub
            sleep 1
            ok "订阅端口已改为 ${p}"
            sub_show
            ;;
        token)
            conf_set SUB_TOKEN "$(rand_hex 16)"
            sub_apply_settings
            ok '订阅令牌已重置'
            sub_show
            ;;
        restart) service_restart_sub; sleep 1; sub_health_check ;;
        check) sub_health_check ;;
        auth)
            local u=${2:-} p=${3:-}
            conf_set SUB_USER "$u"
            conf_set SUB_PASS "$p"
            sub_apply_settings
            if [[ -n $u ]]; then ok "已启用订阅 Basic 认证（用户 ${u}）"; else ok '已关闭订阅 Basic 认证'; fi
            ;;
        *) die "未知子命令：sub $sub" ;;
    esac
}

# ───────────── 内部接口（订阅服务调用） ─────────────
cmd_internal() {
    local sub=${1:-}
    case $sub in
        render)
            case ${2:-} in
                singbox) render_client_singbox ;;
                mihomo) render_client_mihomo ;;
                links) link_all ;;
                v2ray) link_all_b64 ;;
                *) die "未知渲染类型：${2:-}" ;;
            esac
            ;;
        ensure)
            conf_write_defaults
            conf_load
            service_fix_perms
            sub_export_files
            ;;
        *) die "未知内部命令：$sub" ;;
    esac
}

# ───────────── 自更新（脚本本体）─────────────
# 用法：sbox update [分支] [--local <目录>]
cmd_update() {
    local channel=${1:-main}
    local src=${ARGS[local]:-}
    local tmp='' dir='' backup

    if [[ -n $src ]]; then
        [[ -d $src/src && -f $src/sbox.sh ]] || die "本地代码目录无效：$src"
        dir=$src
        info "从本地目录更新：$dir"
    else
        tmp=$(mktemp -d)
        info "从 ${SBOX_SELF_URL} 拉取最新代码（${channel}）"
        local dl=0 url
        for url in "${SBOX_SELF_URL}/archive/${channel}.tar.gz" \
                   "${SBOX_SELF_URL}/archive/refs/heads/${channel}.tar.gz"; do
            if sys_download "$url" "$tmp/src.tar.gz" 2; then dl=1; break; fi
        done
        if ((dl == 0)); then
            rm -rf "$tmp"
            die '拉取失败（内网地址在公网 VPS 不可达时可改用 --local）'
        fi
        tar -xzf "$tmp/src.tar.gz" -C "$tmp" || { rm -rf "$tmp"; die '解包失败'; }
        dir=$(find "$tmp" -maxdepth 1 -mindepth 1 -type d | head -1)
        [[ -n $dir ]] || { rm -rf "$tmp"; die '包内容异常'; }
    fi

    backup=$(mktemp -d)
    cp -a "$SBOX_ROOT/src" "$SBOX_ROOT/VERSION" "$backup/" 2>/dev/null || true
    if ! cp -a "$dir/src" "$SBOX_ROOT/"; then
        err '复制新代码失败，正在回滚'
        cp -a "$backup/src" "$SBOX_ROOT/" 2>/dev/null || true
        rm -rf "$tmp" "$backup"
        die '更新失败'
    fi
    [[ -f $dir/sbox.sh ]] && cp -f "$dir/sbox.sh" "$SBOX_ROOT/sbox.sh" && chmod 755 "$SBOX_ROOT/sbox.sh"
    [[ -f $dir/VERSION ]] && cp -f "$dir/VERSION" "$SBOX_ROOT/VERSION"
    rm -rf "$tmp" "$backup"

    ok "脚本已更新到 v$(sbox_script_version)"
    service_restart_sub || true
}

# ───────────── 卸载 ─────────────
cmd_uninstall() {
    confirm '确认卸载 sbox（服务、配置与节点数据都会删除）？' n || { info '已取消'; return 0; }
    systemctl stop "$SBOX_SINGBOX_SERVICE" "$SBOX_SUB_SERVICE" >/dev/null 2>&1 || true
    systemctl disable "$SBOX_SINGBOX_SERVICE" "$SBOX_SUB_SERVICE" >/dev/null 2>&1 || true
    rm -f "$SBOX_UNIT_DIR/${SBOX_SINGBOX_SERVICE}.service" "$SBOX_UNIT_DIR/${SBOX_SUB_SERVICE}.service"
    systemctl daemon-reload >/dev/null 2>&1 || true
    rm -rf "$SBOX_ETC" "$SBOX_ROOT" "$SB_LINK" "$SBOX_BIN" /etc/sysctl.d/99-sbox-bbr.conf
    if id "$SBOX_USER" >/dev/null 2>&1; then
        userdel "$SBOX_USER" >/dev/null 2>&1 || true
    fi
    ok '已卸载（/var/lib/sbox 保留，可手动删除）'
}

cmd_help() {
    ui_banner
    printf '  %s用法%s  sbox <命令> [参数]\n\n' "$C_BOLD" "$C_RESET"
    printf '  %s节点%s\n' "$C_BOLD" "$C_RESET"
    printf '    sbox node add <vless|hysteria2|anytls|tuic> [--name N] [--port P] [--sni S]\n'
    printf '    sbox node list | show <名称> | link <名称> | edit <名称> | del <名称>\n'
    printf '    sbox node cert [名称]   # 重新生成自签证书 / 查看证书状态\n'
    printf '    sbox node edit <名称> [--port P] [--sni S] [--acme-domain D] [--acme-email E] [--selfsigned]\n\n'
    printf '  %s订阅%s\n' "$C_BOLD" "$C_RESET"
    printf '    sbox sub [show|files|port <端口>|token|auth [用户 密码]|restart|check]\n\n'
    printf '  %s服务%s\n' "$C_BOLD" "$C_RESET"
    printf '    sbox status | start | stop | restart | apply | log\n\n'
    printf '  %s版本%s\n' "$C_BOLD" "$C_RESET"
    printf '    sbox version [report|list|switch <stable|testing|版本号>]\n\n'
    printf '  %s其它%s\n' "$C_BOLD" "$C_RESET"
    printf '    sbox bbr | update | uninstall | menu | help\n\n'
    printf '  %s快捷参数%s  --yes 跳过确认，--name/--port/--sni 用于非交互创建\n' "$C_GREY" "$C_RESET"
    printf '  %s交互菜单%s  直接执行 sbox 即可\n\n' "$C_GREY" "$C_RESET"
}

main_dispatch() {
    local cmd=${1:-menu}
    shift || true
    parse_flags "$@"
    [[ -r $SBOX_CONF ]] && conf_load
    case $cmd in
        menu | '') menu_main ;;
        status) cmd_status ;;
        node)
            local sub=${POSITIONAL[0]:-list}
            case $sub in
                add) node_add "${POSITIONAL[1]:-}"; config_apply; sub_export_files ;;
                list) cmd_node_list "${POSITIONAL[1]:-}" ;;
                show | link) cmd_node_show "${POSITIONAL[1]:-}" ;;
                cert)
                    if [[ -n ${POSITIONAL[1]:-} ]]; then
                        node_regen_cert "${POSITIONAL[1]}"
                    else
                        node_cert_list
                    fi
                    ;;
                del | rm) node_del "${POSITIONAL[1]:-}" "${ARGS[force]:+--force}"; sub_export_files ;;
                edit) node_edit "${POSITIONAL[1]:-}"; sub_export_files ;;
                table) node_table ;;
                *) die "未知子命令：node ${sub}" ;;
            esac
            ;;
        sub) cmd_sub "${POSITIONAL[0]:-show}" "${POSITIONAL[1]:-}" "${POSITIONAL[2]:-}" ;;
        version) cmd_version "${POSITIONAL[0]:-report}" "${POSITIONAL[1]:-}" ;;
        start | enable)
            service_restart_singbox && ok 'sing-box 已启动' ;;
        stop) service_stop_singbox && ok 'sing-box 已停止' ;;
        restart) service_restart_singbox && ok 'sing-box 已重启' ;;
        apply)
            conf_load
            service_install_units
            service_fix_perms
            config_apply
            sub_export_files
            service_restart_sub || true
            ;;
        log) service_log "${POSITIONAL[0]:-40}" ;;
        bbr) sys_enable_bbr ;;
        update) cmd_update "${ARGS[channel]:-main}" ;;
        uninstall) cmd_uninstall ;;
        internal) cmd_internal "${POSITIONAL[0]:-}" "${POSITIONAL[1]:-}" ;;
        install) cmd_install ;;
        doctor) cmd_doctor ;;
        help | -h | --help) cmd_help ;;
        *) die "未知命令：${cmd}（执行 sbox help 查看用法）" ;;
    esac
}

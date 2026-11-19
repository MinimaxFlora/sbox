# shellcheck shell=bash
# menu.sh — 交互式菜单（TUI）

if [[ -n ${SBOX_MENU_SH:-} ]]; then return 0; fi
readonly SBOX_MENU_SH=1

menu_header() {
    clear 2>/dev/null || true
    ui_banner
    local st ver ch n
    if service_active_singbox; then st=$(ui_state running); else st=$(ui_state stopped); fi
    ver=$(sb_current_version 2>/dev/null || echo '未安装')
    ch=$(sb_channel)
    n=$(node_count)
    printf '  %s %s %s   %s%s%s   %s节点 %s 个%s\n' \
        "$st" "$C_GREY|$C_RESET" "$C_GREY$ver ($ch)$C_RESET" "" "" "" "$C_GREY" "$n" "$C_RESET"
    ui_hr
}

menu_main() {
    local choice
    while true; do
        menu_header
        ui_menu_item 1 '状态总览'
        ui_menu_item 2 '添加节点'
        ui_menu_item 3 '节点列表 / 详情'
        ui_menu_item 4 '修改节点'
        ui_menu_item 5 '删除节点'
        ui_menu_item 6 '节点链接 & 二维码'
        ui_menu_item 7 '订阅链接管理'
        ui_menu_item 8 'sing-box 版本管理'
        ui_menu_item c '域名 / 证书管理'
        ui_menu_item 9 '服务控制 & 日志'
        ui_menu_item b 'BBR 加速'
        ui_menu_item u '更新脚本'
        ui_menu_item 0 '退出'
        ui_prompt '选择操作'
        choice=${UI_CHOICE:-}
        case $choice in
            1) cmd_status; pause ;;
            2) menu_add ;;
            3) cmd_node_list; pause ;;
            4) menu_edit ;;
            5) menu_del ;;
            6) menu_link ;;
            7) menu_sub ;;
            8) menu_version ;;
            c | C) cmd_domain list; pause ;;
            9) menu_service ;;
            b | B) sys_enable_bbr; pause ;;
            u | U) cmd_update; pause ;;
            0 | q | Q | '') return 0 ;;
            *) warn '无效选项'; sleep 1 ;;
        esac
    done
}

menu_add() {
    menu_header
    ui_menu_head '添加节点'
    ui_menu_item 1 'VLESS Reality Vision  (TCP, 无需证书, 抗封锁)'
    ui_menu_item 2 'Hysteria2              (QUIC/UDP, 高速)'
    ui_menu_item 3 'AnyTLS                 (TLS 分流, 1.12+)'
    ui_menu_item 4 'TUIC v5                (QUIC/UDP)'
    ui_menu_item 0 '返回'
    ui_prompt '选择协议'
    local c=${UI_CHOICE:-}
    local proto=''
    case $c in
        1) proto=vless ;;
        2) proto=hysteria2 ;;
        3) proto=anytls ;;
        4) proto=tuic ;;
        0 | '') return 0 ;;
        *) warn '无效选项'; return 0 ;;
    esac
    printf '\n'
    case $proto in
        vless) node_add_vless ;;
        hysteria2) node_add_hysteria2 ;;
        anytls) node_add_anytls ;;
        tuic) node_add_tuic ;;
    esac
    config_apply
    sub_export_files
    local added
    added=$(node_names | tail -1)
    link_show "$added"
    pause
}

menu_edit() {
    menu_header
    cmd_node_list
    local name
    name=$(ask '要修改的节点名（留空返回）' '')
    [[ -z $name ]] && return 0
    node_edit "$name"
    sub_export_files
    pause
}

menu_del() {
    menu_header
    cmd_node_list
    local name
    name=$(ask '要删除的节点名（留空返回）' '')
    [[ -z $name ]] && return 0
    node_del "$name"
    sub_export_files
    pause
}

menu_link() {
    menu_header
    cmd_node_list
    local name
    name=$(ask '查看节点名（留空=全部节点链接）' '')
    if [[ -z $name ]]; then
        local n
        printf '\n'
        for n in $(node_names); do
            printf '  %s%s%s\n  %s\n\n' "$C_BOLD" "$n" "$C_RESET" "$(link_for_node "$n")"
        done
    else
        link_show "$name"
    fi
    pause
}

menu_sub() {
    menu_header
    sub_show
    ui_menu_item 1 '重新生成订阅文件'
    ui_menu_item 2 '修改订阅端口'
    ui_menu_item 3 '重置订阅令牌'
    ui_menu_item 4 '重启订阅服务'
    ui_menu_item 5 '健康检查'
    ui_menu_item 0 '返回'
    ui_prompt '选择操作'
    local c=${UI_CHOICE:-}
    case $c in
        1) sub_export_files; config_apply ;;
        2)
            local p
            p=$(ask '新端口' "$(sub_port)")
            valid_port "$p" || { warn '端口不合法'; pause; return 0; }
            sys_firewall_close "$(sub_port)" tcp
            conf_set SUB_PORT "$p"
            sys_firewall_open "$p" tcp
            sub_apply_settings
            service_restart_sub
            sleep 1
            ok "订阅端口已改为 ${p}"
            ;;
        3)
            conf_set SUB_TOKEN "$(rand_hex 16)"
            sub_apply_settings
            ok '订阅令牌已重置'
            sub_show
            ;;
        4) service_restart_sub; sleep 1; service_active_sub && ok '订阅服务已重启' || warn '重启失败' ;;
        5) sub_health_check ;;
        0 | '') return 0 ;;
    esac
    pause
}

menu_version() {
    menu_header
    ui_menu_head 'sing-box 版本管理'
    sb_version_report
    printf '\n'
    ui_menu_item 1 '切换到最新稳定版' "$(sb_channel)"
    ui_menu_item 2 '切换到最新测试版'
    ui_menu_item 3 '指定版本（如 1.14.4）'
    ui_menu_item 4 '列出已安装版本'
    ui_menu_item 0 '返回'
    ui_prompt '选择操作'
    local c=${UI_CHOICE:-}
    case $c in
        1) cmd_version_switch stable ;;
        2) cmd_version_switch testing ;;
        3)
            local tag
            tag=$(ask '版本号（如 1.14.4 / v1.15.0-alpha.13）' '')
            [[ -n $tag ]] && cmd_version_switch "$tag"
            ;;
        4) sb_installed_list | sed 's/^/    /' ;;
        0 | '') return 0 ;;
    esac
    pause
}

menu_service() {
    menu_header
    ui_menu_head '服务控制'
    service_status_summary
    printf '\n'
    ui_menu_item 1 '启动 / 重启 sing-box'
    ui_menu_item 2 '停止 sing-box'
    ui_menu_item 3 '重新应用配置'
    ui_menu_item 4 '查看日志'
    ui_menu_item 0 '返回'
    ui_prompt '选择操作'
    local c=${UI_CHOICE:-}
    case $c in
        1) service_restart_singbox && ok 'sing-box 已重启' ;;
        2) service_stop_singbox && ok 'sing-box 已停止' ;;
        3) config_apply ;;
        4) service_log 50 ;;
        0 | '') return 0 ;;
    esac
    pause
}

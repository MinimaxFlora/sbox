# shellcheck shell=bash
# setup.sh — 安装、初始化与安装后自检

if [[ -n ${SBOX_SETUP_SH:-} ]]; then return 0; fi
readonly SBOX_SETUP_SH=1

cmd_install() {
    need_root
    local channel=${ARGS[channel]:-stable}
    local addr=${ARGS[addr]:-}
    local sub_port=${ARGS[sub-port]:-$SBOX_SUB_PORT_DEFAULT}
    local sub_bind=${ARGS[sub-bind]:-$SBOX_SUB_BIND_DEFAULT}

    ui_banner
    ui_title '安装信息'
    ui_kv '系统' "$(sys_os_name)"
    ui_kv '架构' "$(sys_arch)"
    ui_kv '通道' "$channel"
    ui_kv '目录' "$SBOX_ROOT"
    ui_kv '配置' "$SBOX_ETC"
    printf '\n'

    sys_need_systemd
    sys_ensure_deps

    mkdir -p "$SBOX_ETC" "$SBOX_NODES_DIR" "$SBOX_CERTS_DIR" "$SBOX_SUB_DIR" "$SBOX_STATE" "$SBOX_VERSIONS_DIR"

    if [[ -n $addr ]]; then
        SBOX_ADDR_HINT=$addr conf_write_defaults
        conf_set ADDR "$addr"
    else
        conf_write_defaults
    fi
    [[ -n ${ARGS[sub-port]:-} ]] && conf_set SUB_PORT "$sub_port"
    [[ -n ${ARGS[sub-bind]:-} ]] && conf_set SUB_BIND "$sub_bind"
    [[ -n ${ARGS[reality-sni]:-} ]] && conf_set REALITY_SNI "${ARGS[reality-sni]}"
    conf_load

    info '创建服务用户与 systemd 单元'
    service_ensure_user
    service_install_units

    # sing-box 二进制
    local tag
    case $channel in
        stable | latest) tag=$(sb_remote_tag stable) || die '查询最新稳定版失败（请检查网络或设置 SBOX_GH_MIRROR）' ;;
        testing | beta) tag=$(sb_remote_tag testing) || die '查询最新测试版失败' ;;
        *) tag=$channel ;;
    esac
    [[ $tag == v* ]] || tag="v$tag"
    if [[ -x $SBOX_VERSIONS_DIR/$tag/sing-box ]]; then
        info "sing-box ${tag} 已存在，跳过下载"
    else
        sb_install_version "$tag"
    fi
    sb_link_version "$tag"
    sb_set_state channel "$channel"
    sb_set_state version "$tag"

    info '生成服务端配置'
    render_server_config "$SBOX_SERVER_JSON"
    service_fix_perms

    info '启动服务'
    if [[ $(node_count) -gt 0 ]]; then
        service_restart_singbox || warn 'sing-box 启动失败，请查看日志'
    else
        info '尚未配置节点，sing-box 保持停止状态'
        systemctl enable "$SBOX_SINGBOX_SERVICE" >/dev/null 2>&1 || true
    fi

    # 订阅服务
    if [[ ${ARGS[no-sub]:-0} != 1 ]]; then
        sub_install_service || warn '订阅服务未启动，可稍后执行 sbox sub restart'
        sys_firewall_open "$(sub_port)" tcp
        sub_export_files
    else
        systemctl disable --now "$SBOX_SUB_SERVICE" >/dev/null 2>&1 || true
    fi

    install -m 755 "$SBOX_ROOT/sbox.sh" "$SBOX_ROOT/sbox.sh" 2>/dev/null || true
    ln -sfn "$SBOX_ROOT/sbox.sh" "$SBOX_BIN"

    _install_summary
}

_install_summary() {
    local body=''
    body+="sing-box      $(sb_current_version 2>/dev/null || echo '?')  ($(sb_channel))"$'\n'
    body+="订阅服务      http://$(fmt_host "$(sbox_public_addr 2>/dev/null || echo 127.0.0.1)"):$(sub_port)/<token>/singbox"$'\n'
    body+="配置文件      $SBOX_SERVER_JSON"$'\n'
    body+="管理命令      sbox（直接运行进入交互菜单）"$'\n'
    ui_panel '安装完成' "$body"
    printf '\n  %s下一步%s\n' "$C_BOLD" "$C_RESET"
    printf '    sbox node add vless     %s添加一个 VLESS Reality 节点%s\n' "$C_GREY" "$C_RESET"
    printf '    sbox node add hysteria2 %s添加 Hysteria2 节点%s\n' "$C_GREY" "$C_RESET"
    printf '    sbox sub                %s查看订阅地址%s\n\n' "$C_GREY" "$C_RESET"
}

# 安装后自检（供 CI / 运维使用）
cmd_doctor() {
    local fail=0
    ui_banner
    ui_title '环境自检'

    printf '  %s\n' "$(sys_os_name) / $(sys_arch) / init=$(sys_init)"
    if [[ $(sys_init) == systemd ]]; then ok 'systemd 可用'; else err 'systemd 不可用'; fail=1; fi
    if command -v python3 >/dev/null 2>&1; then ok "python3 $(python3 -V 2>&1 | awk '{print $2}')"; else err 'python3 缺失（订阅服务不可用）'; fi
    if command -v curl >/dev/null 2>&1; then ok 'curl 可用'; else err 'curl 缺失'; fail=1; fi

    local bin ver
    bin=$(sb_current_bin || true)
    if [[ -n $bin && -x $bin ]]; then
        ver=$("$bin" version | head -1)
        ok "sing-box：${ver}"
    else
        err 'sing-box 二进制缺失'; fail=1
    fi

    if [[ -r $SBOX_CONF ]]; then ok "全局配置：$SBOX_CONF"; else err '全局配置缺失'; fail=1; fi
    if [[ $(node_count) -gt 0 ]]; then
        ok "节点数量：$(node_count)"
        if config_validate "$SBOX_SERVER_JSON"; then ok '服务端配置校验通过'; else fail=1; fi
    else
        warn '尚无节点'
    fi
    if service_active_singbox; then ok 'sing-box 运行中'; else warn 'sing-box 未运行'; fi
    if service_active_sub; then ok '订阅服务运行中'; else warn '订阅服务未运行'; fi
    sub_health_check >/dev/null 2>&1 && ok '订阅服务健康' || warn '订阅服务无响应'

    printf '\n'
    if ((fail)); then err '自检发现问题，请按提示修复'; return 1; fi
    ok '自检通过'
}

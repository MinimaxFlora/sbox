# shellcheck shell=bash
# sub.sh — 订阅链接生成与服务管理

if [[ -n ${SBOX_SUB_SH:-} ]]; then return 0; fi
readonly SBOX_SUB_SH=1

sub_token() { conf_get SUB_TOKEN ''; }

sub_port() { conf_get SUB_PORT "$SBOX_SUB_PORT_DEFAULT"; }

# 订阅基础地址（不含 token）
sub_base() {
    local addr port
    addr=$(sbox_public_addr 2>/dev/null || printf '127.0.0.1')
    port=$(sub_port)
    printf 'http://%s:%s' "$(fmt_host "$addr")" "$port"
}

# sub_url <kind>：kind = singbox | mihomo | v2ray | links
sub_url() {
    local kind=$1 token base
    token=$(sub_token)
    base=$(sub_base)
    case $kind in
        singbox) printf '%s/%s/singbox' "$base" "$token" ;;
        mihomo) printf '%s/%s/mihomo' "$base" "$token" ;;
        v2ray) printf '%s/%s/v2ray' "$base" "$token" ;;
        links) printf '%s/%s/links' "$base" "$token" ;;
        auto) printf '%s/%s/auto' "$base" "$token" ;;
        *) printf '%s/%s/%s' "$base" "$token" "$kind" ;;
    esac
}

sub_show() {
    [[ $(node_count) -gt 0 ]] || { warn "尚无节点，先添加节点再生成订阅"; return 1; }
    local u
    printf '\n'
    ui_kv '客户端' '订阅地址'
    ui_hr
    u=$(sub_url singbox); printf '  %s%-10s%s %s\n' "$C_BOLD" 'sing-box' "$C_RESET" "$u"
    u=$(sub_url mihomo);  printf '  %s%-10s%s %s\n' "$C_BOLD" 'mihomo' "$C_RESET" "$u"
    u=$(sub_url v2ray);   printf '  %s%-10s%s %s\n' "$C_BOLD" 'v2rayN' "$C_RESET" "$u"
    u=$(sub_url auto);    printf '  %s%-10s%s %s\n' "$C_BOLD" '自动识别' "$C_RESET" "$u"
    printf '\n  %s说明：sing-box 订阅为 1.12+ 新格式 JSON；mihomo 为 Clash 内核 YAML；v2rayN/小火箭使用 Base64 链接列表。%s\n' "$C_GREY" "$C_RESET"
    printf '\n'
    u=$(sub_url singbox)
    link_qr "$u" terminal || true
}

# 订阅文件落盘（调试 / 静态托管用）
sub_export_files() {
    mkdir -p "$SBOX_SUB_DIR"
    render_client_singbox >"$SBOX_SUB_DIR/singbox.json" 2>/dev/null || true
    render_client_mihomo >"$SBOX_SUB_DIR/mihomo.yaml" 2>/dev/null || true
    link_all >"$SBOX_SUB_DIR/links.txt" 2>/dev/null || true
    link_all_b64 >"$SBOX_SUB_DIR/links.b64" 2>/dev/null || true
    chmod 640 "$SBOX_SUB_DIR"/* 2>/dev/null || true
    chown -R "root:${SBOX_USER}" "$SBOX_SUB_DIR" 2>/dev/null || true
}

sub_install_service() {
    sys_need_systemd
    if ! command -v python3 >/dev/null 2>&1; then
        warn "缺少 python3，无法启动订阅服务（可执行 apt install python3）"
        return 1
    fi
    service_write_sub_unit || return 1
    systemctl daemon-reload
    service_start_sub
    sleep 1
    if service_active_sub; then
        ok "订阅服务已启动（端口 $(sub_port)）"
    else
        warn "订阅服务启动失败：journalctl -u ${SBOX_SUB_SERVICE} -n 30"
        return 1
    fi
}

sub_health_check() {
    local url code
    url="http://127.0.0.1:$(sub_port)/health"
    code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' "$url" 2>/dev/null || true)
    if [[ $code == 200 ]]; then
        ok "订阅服务健康检查通过（${url}）"
    else
        warn "订阅服务健康检查失败（HTTP ${code:-无响应}）"
        return 1
    fi
}

sub_apply_settings() { # 修改令牌/认证后应用（订阅服务每次请求都会重读配置，无需重启）
    conf_load
    service_fix_perms
    sub_export_files
    sub_install_service || true
}

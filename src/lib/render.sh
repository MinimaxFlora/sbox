# shellcheck shell=bash
# render.sh — 服务端配置 / 客户端 sing-box 配置 / mihomo 配置生成与校验

if [[ -n ${SBOX_RENDER_SH:-} ]]; then return 0; fi
readonly SBOX_RENDER_SH=1

# 监听地址：IPv6 可用则 ::，否则 0.0.0.0
server_listen() {
    local node=$1 a
    a=$(node_meta "$node" listen)
    if [[ -n $a ]]; then printf '%s' "$a"; return 0; fi
    if [[ -r /proc/sys/net/ipv6/conf/all/disable_ipv6 ]] \
        && [[ $(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || echo 0) == 1 ]]; then
        printf '0.0.0.0'
    else
        printf '::'
    fi
}

# 生成 inbound 的 tls 字段（含 alpn，可为空）
_render_tls_inbound() {
    local name=$1 alpn=${2:-} mode sni domain email cert key acme_json=''
    mode=$(node_meta "$name" tls_mode selfsigned)
    sni=$(node_meta "$name" sni "${SBOX_TLS_SNI:-$SBOX_TLS_SNI_DEFAULT}")
    case $mode in
        selfsigned)
            cert="$SBOX_CERTS_DIR/$name/cert.pem"
            key="$SBOX_CERTS_DIR/$name/key.pem"
            [[ -r $cert && -r $key ]] || diewarn_cert "$name"
            ;;
        manual)
            cert=$(node_meta "$name" cert_file)
            key=$(node_meta "$name" key_file)
            [[ -r $cert && -r $key ]] || diewarn_cert "$name"
            ;;
        acme)
            domain=$(node_meta "$name" acme_domain "$sni")
            email=$(node_meta "$name" acme_email 'admin@example.com')
            acme_json=", \"acme\": { \"domain\": [\"$(json_escape "$domain")\"], \"email\": \"$(json_escape "$email")\" }"
            sni=$domain
            ;;
        none) printf '{ "enabled": false }'; return 0 ;;
        *) die "未知证书模式：$mode" ;;
    esac

    local alpn_json=''
    [[ -n $alpn ]] && alpn_json=", \"alpn\": [\"$alpn\"]"
    printf '{ "enabled": true, "server_name": "%s"%s%s, "certificate_path": "%s", "key_path": "%s" }' \
        "$(json_escape "$sni")" "$alpn_json" "$acme_json" \
        "$(json_escape "$cert")" "$(json_escape "$key")"
}

diewarn_cert() {
    die "节点 $(node_meta "$1" name) 的证书文件缺失，请执行 sbox node edit $1 重新生成"
}

# 单个节点 → 服务端 inbound JSON
_render_inbound() {
    local name=$1 type port listen uuid pw sni flow fp priv sid masq obfs obfspw
    local congestion relay
    type=$(node_type "$name")
    port=$(node_meta "$name" port)
    listen=$(server_listen "$name")
    sni=$(node_meta "$name" sni)

    case $type in
        vless)
            uuid=$(node_meta "$name" uuid)
            flow=$(node_meta "$name" flow)
            priv=$(node_meta "$name" reality_private)
            sid=$(node_meta "$name" short_id)
            local flow_json=''
            [[ -n $flow ]] && flow_json=", \"flow\": \"$(json_escape "$flow")\""
            printf '{"type":"vless","tag":"vless-%s","listen":"%s","listen_port":%s,' \
                "$name" "$listen" "$port"
            printf '"users":[{"name":"%s","uuid":"%s"%s}],' \
                "$name" "$(json_escape "$uuid")" "$flow_json"
            printf '"tls":{"enabled":true,"server_name":"%s","reality":{"enabled":true,' \
                "$(json_escape "$sni")"
            printf '"handshake":{"server":"%s","server_port":443},' "$(json_escape "$sni")"
            printf '"private_key":"%s","short_id":["%s"]}}}' \
                "$(json_escape "$priv")" "$(json_escape "$sid")"
            ;;
        hysteria2)
            pw=$(node_meta "$name" password)
            masq=$(node_meta "$name" masquerade)
            obfs=$(node_meta "$name" obfs)
            obfspw=$(node_meta "$name" obfs_password)
            local msq_json='' obfs_json=''
            [[ -n $masq ]] && msq_json=", \"masquerade\": \"$(json_escape "$masq")\""
            if [[ -n $obfs ]]; then
                obfs_json=", \"obfs\": { \"type\": \"$(json_escape "$obfs")\", \"password\": \"$(json_escape "$obfspw")\" }"
            fi
            printf '{"type":"hysteria2","tag":"hysteria2-%s","listen":"%s","listen_port":%s,' \
                "$name" "$listen" "$port"
            printf '"users":[{"name":"%s","password":"%s"}]%s%s,' \
                "$name" "$(json_escape "$pw")" "$msq_json" "$obfs_json"
            printf '"tls":%s}' "$(_render_tls_inbound "$name" h3)"
            ;;
        anytls)
            pw=$(node_meta "$name" password)
            printf '{"type":"anytls","tag":"anytls-%s","listen":"%s","listen_port":%s,' \
                "$name" "$listen" "$port"
            printf '"users":[{"name":"%s","password":"%s"}],' "$name" "$(json_escape "$pw")"
            printf '"tls":%s}' "$(_render_tls_inbound "$name" h2)"
            ;;
        tuic)
            uuid=$(node_meta "$name" uuid)
            pw=$(node_meta "$name" password)
            congestion=$(node_meta "$name" congestion bbr)
            printf '{"type":"tuic","tag":"tuic-%s","listen":"%s","listen_port":%s,' \
                "$name" "$listen" "$port"
            printf '"users":[{"name":"%s","uuid":"%s","password":"%s"}],' \
                "$name" "$(json_escape "$uuid")" "$(json_escape "$pw")"
            printf '"congestion_control":"%s","zero_rtt_handshake":false,' "$(json_escape "$congestion")"
            printf '"tls":%s}' "$(_render_tls_inbound "$name" h3)"
            ;;
        *) die "未知节点类型：$type（$name）" ;;
    esac
}

# 生成服务端配置到文件
render_server_config() {
    local out=${1:-$SBOX_SERVER_JSON} names n first=1 tmp
    names=$(node_names)
    tmp=$(mktemp)

    {
        printf '{\n'
        printf '  "log": { "level": "warn", "timestamp": true },\n'
        printf '  "inbounds": [\n'
        for n in $names; do
            [[ $first == 1 ]] || printf ',\n'
            first=0
            printf '    %s' "$(_render_inbound "$n")"
        done
        [[ $first == 0 ]] && printf '\n'
        printf '  ],\n'
        printf '  "outbounds": [\n'
        printf '    { "type": "direct", "tag": "direct" }\n'
        printf '  ],\n'
        printf '  "route": {\n'
        printf '    "rules": [\n'
        printf '      { "action": "reject", "ip_is_private": true }\n'
        printf '    ],\n'
        printf '    "final": "direct"\n'
        printf '  }\n'
        printf '}\n'
    } >"$tmp"

    if ! config_validate "$tmp"; then
        rm -f "$tmp"
        die "生成的服务端配置未通过 sing-box 校验"
    fi
    install -m 600 "$tmp" "$out"
    sbox_chown_ro "$out"
    rm -f "$tmp"
    debug "服务端配置已生成：$out"
}

# config_validate <文件>：调用当前 sing-box 二进制校验
config_validate() {
    local file=$1 bin out
    bin=$(sb_current_bin) || bin=''
    if [[ -z $bin ]]; then
        warn "sing-box 二进制缺失，跳过配置校验"
        return 0
    fi
    if ! out=$("$bin" check -c "$file" 2>&1); then
        err "配置校验失败："
        printf '%s\n' "$out" | sed 's/^/    /' >&2
        return 1
    fi
    return 0
}

# 应用配置：备份 → 生成 → 校验 → 重启；失败自动回滚
config_apply() {
    local backup=''
    if [[ -s $SBOX_SERVER_JSON ]]; then
        backup=$(mktemp)
        cp -p "$SBOX_SERVER_JSON" "$backup"
    fi

    if ! render_server_config "$SBOX_SERVER_JSON"; then
        [[ -n $backup ]] && cp -p "$backup" "$SBOX_SERVER_JSON"
        [[ -n $backup ]] && rm -f "$backup"
        die "配置生成失败，已回滚到上一版本"
    fi

    local n
    for n in $(node_names); do
        sys_firewall_open "$(node_meta "$n" port)" "$(node_port_proto "$n")"
    done

    # 服务以非 root 用户运行，配置/证书需要对该用户只读
    service_fix_perms

    if [[ $(node_count) -eq 0 ]]; then
        info "当前没有节点，服务保持停止"
        service_stop_singbox || true
    else
        if ! service_restart_singbox; then
            err "服务启动失败，正在回滚配置"
            if [[ -n $backup ]]; then
                cp -p "$backup" "$SBOX_SERVER_JSON"
                service_restart_singbox || true
                die "服务启动失败，已回滚（journalctl -u ${SBOX_SINGBOX_SERVICE} -n 50）"
            fi
            die "服务启动失败（journalctl -u ${SBOX_SINGBOX_SERVICE} -n 50）"
        fi
        ok "配置已生效，当前 $(node_count) 个节点"
    fi
    [[ -n $backup ]] && rm -f "$backup"
    return 0
}

# ─────────────────────── 客户端 outbound（sing-box 1.12+） ───────────────────────
_render_client_outbound() {
    local name=$1 type server port sni mode insecure tag
    type=$(node_type "$name")
    server=$(node_addr "$name")
    port=$(node_meta "$name" port)
    sni=$(node_meta "$name" sni)
    mode=$(node_meta "$name" tls_mode)
    tag="node-${name}"

    local tls json_insecure='false'
    [[ $mode != reality && $mode != acme && $mode != manual ]] && json_insecure='true'
    # 手动证书默认可信；自签需要允许不安全
    [[ $mode == manual ]] && json_insecure='false'

    _client_tls() { # <alpn|''>
        local alpn=${1:-} alpn_json=''
        [[ -n $alpn ]] && alpn_json=",\"alpn\":[\"$alpn\"]"
        if [[ $mode == reality ]]; then
            printf '{"enabled":true,"server_name":"%s","utls":{"enabled":true,"fingerprint":"%s"},"reality":{"enabled":true,"public_key":"%s","short_id":"%s"}}' \
                "$(json_escape "$sni")" \
                "$(json_escape "$(node_meta "$name" fingerprint chrome)")" \
                "$(json_escape "$(node_meta "$name" reality_public)")" \
                "$(json_escape "$(node_meta "$name" short_id)")"
        else
            printf '{"enabled":true,"server_name":"%s"%s,"insecure":%s}' \
                "$(json_escape "$sni")" "$alpn_json" "$json_insecure"
        fi
    }

    case $type in
        vless)
            printf '{"type":"vless","tag":"%s","server":"%s","server_port":%s,' \
                "$tag" "$(json_escape "$server")" "$port"
            printf '"uuid":"%s","flow":"%s",' \
                "$(json_escape "$(node_meta "$name" uuid)")" \
                "$(json_escape "$(node_meta "$name" flow)")"
            printf '"packet_encoding":"xudp","tls":%s}' "$(_client_tls '')"
            ;;
        hysteria2)
            printf '{"type":"hysteria2","tag":"%s","server":"%s","server_port":%s,' \
                "$tag" "$(json_escape "$server")" "$port"
            printf '"password":"%s"' "$(json_escape "$(node_meta "$name" password)")"
            local obfs obfspw
            obfs=$(node_meta "$name" obfs)
            obfspw=$(node_meta "$name" obfs_password)
            if [[ -n $obfs ]]; then
                printf ',"obfs":{"type":"%s","password":"%s"}' \
                    "$(json_escape "$obfs")" "$(json_escape "$obfspw")"
            fi
            printf ',"tls":%s}' "$(_client_tls h3)"
            ;;
        anytls)
            printf '{"type":"anytls","tag":"%s","server":"%s","server_port":%s,' \
                "$tag" "$(json_escape "$server")" "$port"
            printf '"password":"%s","tls":%s}' \
                "$(json_escape "$(node_meta "$name" password)")" "$(_client_tls h2)"
            ;;
        tuic)
            printf '{"type":"tuic","tag":"%s","server":"%s","server_port":%s,' \
                "$tag" "$(json_escape "$server")" "$port"
            printf '"uuid":"%s","password":"%s","congestion_control":"%s","udp_relay_mode":"%s",' \
                "$(json_escape "$(node_meta "$name" uuid)")" \
                "$(json_escape "$(node_meta "$name" password)")" \
                "$(json_escape "$(node_meta "$name" congestion bbr)")" \
                "$(json_escape "$(node_meta "$name" udp_relay_mode native)")"
            printf '"tls":%s}' "$(_client_tls h3)"
            ;;
        *) die "未知节点类型：$type" ;;
    esac
}

# 生成 sing-box 客户端配置（订阅用，新格式 1.12+）
render_client_singbox() {
    local names n first=1 tags=''
    names=$(node_names)
    [[ -n $names ]] || return 1

    printf '{\n'
    printf '  "log": { "level": "info", "timestamp": true },\n'
    printf '  "dns": {\n'
    printf '    "servers": [\n'
    printf '      { "type": "local", "tag": "dns-local" },\n'
    printf '      { "type": "https", "tag": "dns-remote", "server": "1.1.1.1", "detour": "proxy" }\n'
    printf '    ],\n'
    printf '    "rules": [\n'
    printf '      { "domain_suffix": [".lan", ".local", ".localdomain"], "server": "dns-local" }\n'
    printf '    ],\n'
    printf '    "final": "dns-remote"\n'
    printf '  },\n'
    printf '  "inbounds": [\n'
    printf '    { "type": "tun", "tag": "tun-in", "address": ["172.19.0.1/30", "fdfe:dcba:9876::1/126"], "mtu": 9000, "auto_route": true, "strict_route": true, "stack": "mixed" },\n'
    printf '    { "type": "mixed", "tag": "mixed-in", "listen": "127.0.0.1", "listen_port": 2080 }\n'
    printf '  ],\n'
    printf '  "outbounds": [\n'
    for n in $names; do
        [[ $first == 1 ]] || printf ',\n'
        first=0
        printf '    %s' "$(_render_client_outbound "$n")"
        tags="${tags:+$tags, }\"node-$n\""
    done
    printf ',\n'
    printf '    { "type": "selector", "tag": "proxy", "outbounds": [%s], "default": "node-%s" },\n' \
        "$tags" "$(node_names | head -1)"
    printf '    { "type": "direct", "tag": "direct" }\n'
    printf '  ],\n'
    printf '  "route": {\n'
    printf '    "default_domain_resolver": { "server": "dns-remote" },\n'
    printf '    "rules": [\n'
    printf '      { "action": "sniff" },\n'
    printf '      { "protocol": "dns", "action": "hijack-dns" },\n'
    printf '      { "ip_is_private": true, "action": "route", "outbound": "direct" }\n'
    printf '    ],\n'
    printf '    "final": "proxy"\n'
    printf '  },\n'
    printf '  "experimental": { "cache_file": { "enabled": true }, "clash_api": { "external_controller": "127.0.0.1:9090" } }\n'
    printf '}\n'
}

# 生成 mihomo / Clash 配置
render_client_mihomo() {
    local names n first=1 mode sni server port pw
    names=$(node_names)
    [[ -n $names ]] || return 1

    printf '# sbox 生成 · mihomo 配置\n'
    printf 'mixed-port: 7890\nallow-lan: false\nmode: rule\nlog-level: info\nipv6: true\n'
    printf 'unified-delay: true\ntcp-concurrent: true\n'
    printf 'proxies:\n'
    for n in $names; do
        mode=$(node_meta "$n" tls_mode)
        sni=$(node_meta "$n" sni)
        server=$(node_addr "$n")
        port=$(node_meta "$n" port)
        printf '  - name: %s\n' "$(yaml_scalar "$n")"
        case $(node_type "$n") in
            vless)
                printf '    type: vless\n    server: %s\n    port: %s\n' "$(yaml_scalar "$server")" "$port"
                printf '    uuid: %s\n    network: tcp\n    udp: true\n    tls: true\n' "$(yaml_scalar "$(node_meta "$n" uuid)")"
                printf '    flow: %s\n' "$(yaml_scalar "$(node_meta "$n" flow)")"
                printf '    servername: %s\n' "$(yaml_scalar "$sni")"
                printf '    client-fingerprint: %s\n' "$(yaml_scalar "$(node_meta "$n" fingerprint chrome)")"
                printf '    reality-opts:\n      public-key: %s\n      short-id: %s\n' \
                    "$(yaml_scalar "$(node_meta "$n" reality_public)")" \
                    "$(yaml_scalar "$(node_meta "$n" short_id)")"
                printf '    skip-cert-verify: false\n'
                ;;
            hysteria2)
                printf '    type: hysteria2\n    server: %s\n    port: %s\n' "$(yaml_scalar "$server")" "$port"
                printf '    password: %s\n    sni: %s\n    alpn: [h3]\n' \
                    "$(yaml_scalar "$(node_meta "$n" password)")" "$(yaml_scalar "$sni")"
                [[ $mode == selfsigned ]] && printf '    skip-cert-verify: true\n'
                [[ $mode == acme || $mode == manual ]] && printf '    skip-cert-verify: false\n'
                local obfs
                obfs=$(node_meta "$n" obfs)
                if [[ -n $obfs ]]; then
                    printf '    obfs: %s\n    obfs-password: %s\n' \
                        "$(yaml_scalar "$obfs")" "$(yaml_scalar "$(node_meta "$n" obfs_password)")"
                fi
                ;;
            anytls)
                printf '    type: anytls\n    server: %s\n    port: %s\n' "$(yaml_scalar "$server")" "$port"
                printf '    password: %s\n    sni: %s\n    alpn: [h2]\n    udp: true\n' \
                    "$(yaml_scalar "$(node_meta "$n" password)")" "$(yaml_scalar "$sni")"
                printf '    client-fingerprint: chrome\n'
                [[ $mode == selfsigned ]] && printf '    skip-cert-verify: true\n'
                ;;
            tuic)
                printf '    type: tuic\n    server: %s\n    port: %s\n' "$(yaml_scalar "$server")" "$port"
                printf '    uuid: %s\n    password: %s\n    sni: %s\n    alpn: [h3]\n' \
                    "$(yaml_scalar "$(node_meta "$n" uuid)")" \
                    "$(yaml_scalar "$(node_meta "$n" password)")" "$(yaml_scalar "$sni")"
                printf '    congestion-controller: %s\n    udp-relay-mode: %s\n    reduce-rtt: true\n' \
                    "$(yaml_scalar "$(node_meta "$n" congestion bbr)")" \
                    "$(yaml_scalar "$(node_meta "$n" udp_relay_mode native)")"
                [[ $mode == selfsigned ]] && printf '    skip-cert-verify: true\n'
                ;;
        esac
    done

    printf 'proxy-groups:\n'
    printf '  - name: 节点选择\n    type: select\n    proxies:\n'
    for n in $names; do printf '      - %s\n' "$(yaml_scalar "$n")"; done
    printf '  - name: 自动选择\n    type: url-test\n    url: http://www.gstatic.com/generate_204\n    interval: 300\n    tolerance: 50\n    proxies:\n'
    for n in $names; do printf '      - %s\n' "$(yaml_scalar "$n")"; done
    printf 'rules:\n'
    printf '  - GEOIP,LAN,DIRECT,no-resolve\n'
    printf '  - GEOIP,CN,DIRECT\n'
    printf '  - MATCH,节点选择\n'
}

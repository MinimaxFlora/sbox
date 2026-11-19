# shellcheck shell=bash
# node.sh — 节点（入站）数据模型与增删改查
# 节点元数据以 key=value 存放于 /etc/sbox/nodes/<name>.meta，不使用 eval 解析。

if [[ -n ${SBOX_NODE_SH:-} ]]; then return 0; fi
readonly SBOX_NODE_SH=1

readonly NODE_PROTO_LABEL_vless='VLESS Reality'
readonly NODE_PROTO_LABEL_hysteria2='Hysteria2'
readonly NODE_PROTO_LABEL_anytls='AnyTLS'
readonly NODE_PROTO_LABEL_tuic='TUIC v5'

node_file() { printf '%s/%s.meta' "$SBOX_NODES_DIR" "$1"; }

node_exists() {
    [[ -n ${1:-} ]] && valid_name "$1" && [[ -r $(node_file "$1") ]]
}

node_meta() { # node_meta <name> <key> [default]
    local name=$1 key=$2 def=${3:-} f val
    f=$(node_file "$name")
    [[ -r $f ]] || { printf '%s' "$def"; return 0; }
    val=$(awk -v k="$key" 'index($0, k "=") == 1 { sub(/^[^=]*=/, ""); print; exit }' "$f")
    if [[ -z $val && -n $def ]]; then printf '%s' "$def"; else printf '%s' "$val"; fi
}

node_meta_set() { # node_meta_set <name> <key> <value>
    local name=$1 key=$2 val=$3 f tmp
    f=$(node_file "$name")
    [[ -r $f ]] || die "节点 ${name} 不存在"
    tmp=$(mktemp)
    awk -v k="$key" -v v="$val" '
        BEGIN { done = 0 }
        index($0, k "=") == 1 { if (!done) { print k "=" v; done = 1 }; next }
        { print }
        END { if (!done) print k "=" v }
    ' "$f" >"$tmp"
    mv "$tmp" "$f"
    sbox_chown_ro "$f"
}

node_write() { # node_write <name>：从 stdin 写入元数据
    local name=$1 f
    f=$(node_file "$name")
    mkdir -p "$SBOX_NODES_DIR"
    cat >"$f"
    sbox_chown_ro "$f"
}

node_names() {
    local f
    for f in "$SBOX_NODES_DIR"/*.meta; do
        [[ -r $f ]] || continue
        basename "$f" .meta
    done | sort
}

node_count() {
    local n
    n=$(node_names | grep -c . || true)
    printf '%s' "${n:-0}"
}

node_type() { node_meta "$1" type; }

node_proto_label() {
    local t=${1:-}
    case $t in
        vless) printf '%s' "$NODE_PROTO_LABEL_vless" ;;
        hysteria2) printf '%s' "$NODE_PROTO_LABEL_hysteria2" ;;
        anytls) printf '%s' "$NODE_PROTO_LABEL_anytls" ;;
        tuic) printf '%s' "$NODE_PROTO_LABEL_tuic" ;;
        *) printf '%s' "$t" ;;
    esac
}

# 节点使用的端口（去重，供端口分配参考）
node_used_ports() {
    local n
    for n in $(node_names); do node_meta "$n" port; done | sort -u
}

# 指定节点对外地址：节点覆盖 > 全局配置 > 自动探测
node_addr() { # 客户端连接地址：显式覆盖 > 证书域名 > 本机公网地址
    local name=$1 addr sni mode
    addr=$(node_meta "$name" addr)
    if [[ -n $addr ]]; then printf '%s' "$addr"; return 0; fi
    mode=$(node_meta "$name" tls_mode)
    # TLS 类协议：证书名是域名时用域名（ACME 签发的证书必须用域名访问）
    if [[ $mode != reality ]]; then
        sni=$(node_meta "$name" sni)
        if [[ -n $sni ]] && valid_domain "$sni"; then
            printf '%s' "$sni"
            return 0
        fi
    fi
    sbox_public_addr 2>/dev/null || printf '127.0.0.1'
}

# 链接中主机字段：IPv6 需加方括号
fmt_host() {
    local h=$1
    if [[ $h == *:* && $h != \[* ]]; then printf '[%s]' "$h"; else printf '%s' "$h"; fi
}

node_port_proto() { # TCP / UDP
    case $(node_type "$1") in
        hysteria2 | tuic) printf 'udp' ;;
        *) printf 'tcp' ;;
    esac
}

# 端口冲突检测：同协议栈下已有节点占用，或系统端口被占用
node_port_taken() { # node_port_taken <port> <tcp|udp> [忽略节点名]
    local port=$1 proto=$2 ignore=${3:-} n p np
    for n in $(node_names); do
        [[ $n == "$ignore" ]] && continue
        p=$(node_meta "$n" port)
        np=$(node_port_proto "$n")
        [[ $p == "$port" && $np == "$proto" ]] && return 0
    done
    return 1
}

# ────────────────────────── 新增节点 ──────────────────────────
# 读取命令行参数：同时兼容 --obfs-password 与 obfs_password 两种写法
pget() {
    local key=$1 def=${2:-} val=''
    val=${ARGS[$key]:-}
    [[ -z $val ]] && val=${ARGS[${key//_/-}]:-}
    [[ -z $val ]] && val=${ARGS[${key//-/_}]:-}
    if [[ -n $val ]]; then printf '%s' "$val"; else printf '%s' "$def"; fi
}

_node_default_name() {
    local base=$1 n=1 name
    name=$base
    while node_exists "$name"; do
        n=$((n + 1))
        name="${base}-${n}"
    done
    printf '%s' "$name"
}

_node_ask_name() {
    local suggested=$1 name
    name=$(pget name '')
    if [[ -z $name && -t 0 ]]; then
        name=$(ask '节点名称（字母/数字/下划线）' "$suggested")
    fi
    [[ -z $name ]] && name=$suggested
    valid_name "$name" || { [[ -t 0 ]] && die "名称不合法：${name}" || name=$suggested; }
    node_exists "$name" && die "节点 ${name} 已存在"
    printf '%s' "$name"
}

_node_ask_port() {
    local proto=$1 preferred=${2:-} port
    port=$(pget port '')
    if [[ -n $port ]]; then
        valid_port "$port" || die "端口不合法：${port}"
        if node_port_taken "$port" "$proto"; then die "端口 ${port}/${proto} 已被其它节点占用"; fi
        if ! sys_port_free "$port" "$proto"; then warn "端口 ${port}/${proto} 当前被其它程序占用，仍继续"; fi
        printf '%s' "$port"
        return 0
    fi
    port=$(sys_alloc_port '' "$proto" "$preferred")
    [[ -n $port ]] || die "无法找到可用端口"
    if [[ -t 0 ]]; then
        port=$(ask "端口（${proto}，回车使用推荐值）" "$port")
        valid_port "$port" || die "端口不合法：${port}"
    fi
    printf '%s' "$port"
}

_node_ask_sni() { # Reality 专用：<默认借用站点>
    local def=$1 sni
    sni=$(pget sni '')
    if [[ -z $sni && -t 0 ]]; then
        sni=$(ask 'Reality SNI（借用的 TLS1.3 站点域名）' "$def")
    fi
    [[ -z $sni ]] && sni=$def
    valid_ip_or_host "$sni" || die "Reality SNI 不合法：${sni}"
    printf '%s' "$sni"
}

# ACME 域名：走域名库（已有证书直接复用，避免重复申请）——见 src/lib/domain.sh

# 自签/手动证书的名称：默认用服务器地址，不再用任何伪装域名
_node_ask_cert_name() {
    local def=$1 name
    name=$(pget sni '')
    if [[ -z $name && -t 0 ]]; then
        name=$(ask '证书名称 / SNI（域名或服务器 IP，自签证书写入该名称）' "$def")
    fi
    [[ -z $name ]] && name=$def
    [[ -n $name ]] || die '需要证书名称：--sni 域名或服务器 IP'
    valid_ip_or_host "$name" || die "证书名称不合法：${name}"
    printf '%s' "$name"
}

_node_ask_cert_mode() { # 返回 selfsigned / acme / manual
    local mode
    mode=$(pget cert '')
    if [[ -n $mode ]]; then printf '%s' "$mode"; return 0; fi
    if [[ ! -t 0 ]]; then printf 'selfsigned'; return 0; fi
    printf '\n  %s证书方式%s\n' "$C_BOLD" "$C_RESET" >&2
    printf '   1) 自签证书      %s无需域名，客户端需允许不安全 TLS（默认）%s\n' "$C_GREY" "$C_RESET" >&2
    printf '   2) ACME 自动签发 %s需域名解析到本机，且 80 端口可达%s\n' "$C_GREY" "$C_RESET" >&2
    printf '   3) 手动证书      %s使用已有 cert/key 文件%s\n' "$C_GREY" "$C_RESET" >&2
    local c
    c=$(ask '选择' '1')
    case $c in
        2) printf 'acme' ;;
        3) printf 'manual' ;;
        *) printf 'selfsigned' ;;
    esac
}

_node_prepare_tls() { # <name> <mode> <sni> [acme_domain] → 输出需要保存的 meta 片段
    local name=$1 mode=$2 sni=$3 domain=${4:-} email cert key
    case $mode in
        selfsigned)
            tls_generate_selfsigned "$name" "$sni" >&2
            ;;
        acme)
            email=$(pget acme_email '')
            if [[ -z $email ]]; then
                email=$(domain_field "$domain" EMAIL 2>/dev/null || true)
            fi
            if [[ -z $email && -t 0 ]]; then
                email=$(ask 'ACME 账号邮箱（可留空）' '')
                [[ -n $email ]] && domain_record "$domain" "$email"
            fi
            printf 'acme_domain=%s\nacme_email=%s\n' "$domain" "$email"
            ;;
        manual)
            cert=$(pget cert_file '')
            key=$(pget key_file '')
            if [[ -z $cert || -z $key ]]; then
                if [[ -t 0 ]]; then
                    cert=$(ask '证书文件路径' '')
                    key=$(ask '私钥文件路径' '')
                fi
            fi
            [[ -r $cert && -r $key ]] || die "证书/私钥文件不可读：${cert} / ${key}"
            printf 'cert_file=%s\nkey_file=%s\n' "$cert" "$key"
            ;;
        *) return 0 ;;
    esac
}

node_add_vless() {
    local name port sni uuid flow priv pub sid fingerprint
    name=$(_node_ask_name "$(_node_default_name 'vless')") || die '节点名称无效'
    port=$(_node_ask_port tcp 443) || die '端口不可用'
    sni=$(_node_ask_sni "${SBOX_REALITY_SNI:-$SBOX_REALITY_SNI_DEFAULT}") || die 'Reality SNI 无效'
    flow=$(pget flow 'xtls-rprx-vision')
    fingerprint=$(pget fingerprint 'chrome')
    uuid=$(pget uuid '')
    [[ -z $uuid ]] && uuid=$(gen_uuid)
    valid_uuid "$uuid" || die "UUID 不合法"

    local kp priv pub
    kp=$("$(sbox_singbox_path)" generate reality-keypair 2>/dev/null) \
        || die "生成 Reality 密钥失败（sing-box 未安装？）"
    priv=$(awk -F': ' '/PrivateKey/ {print $2; exit}' <<<"$kp")
    pub=$(awk -F': ' '/PublicKey/ {print $2; exit}' <<<"$kp")
    sid=$(pget short_id "$(gen_short_id)")

    node_write "$name" <<EOF
name=$name
type=vless
port=$port
listen=::
uuid=$uuid
flow=$flow
sni=$sni
fingerprint=$fingerprint
reality_private=$priv
reality_public=$pub
short_id=$sid
tls_mode=reality
created=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
    ok "已添加 VLESS Reality 节点：${name} (${port}/tcp, SNI ${sni})"
}

node_add_hysteria2() {
    local name port sni pw certmode masq obfs obfspw acme_domain=''
    name=$(_node_ask_name "$(_node_default_name 'hy2')") || die '节点名称无效'
    port=$(_node_ask_port udp 443) || die '端口不可用'
    masq=$(pget masquerade "${SBOX_MASQUERADE:-$SBOX_MASQUERADE_DEFAULT}")
    pw=$(pget password '')
    [[ -z $pw ]] && pw=$(gen_password)
    certmode=$(_node_ask_cert_mode)

    # 证书名称：ACME 用真实域名，自签/手动默认用服务器地址（绝不默认 third-party 域名）
    if [[ $certmode == acme ]]; then
        acme_domain=$(domain_choose) || die 'ACME 域名无效，节点未创建'
        sni=$acme_domain
    else
        sni=$(_node_ask_cert_name "$(sbox_public_addr 2>/dev/null || printf '127.0.0.1')") || die '证书名称无效，节点未创建'
    fi

    obfs=$(pget obfs '')
    obfspw=$(pget obfs_password '')
    if [[ -n $obfs && -z $obfspw ]]; then
        die "启用 obfs（${obfs}）时必须提供 --obfs-password"
    fi

    local tls_meta=''
    if [[ $certmode != none ]]; then
        tls_meta=$(_node_prepare_tls "$name" "$certmode" "$sni" "$acme_domain") \
            || die "证书准备失败（模式：${certmode}），节点未创建"
    fi

    {
        cat <<EOF
name=$name
type=hysteria2
port=$port
listen=::
sni=$sni
password=$pw
tls_mode=$certmode
masquerade=$masq
EOF
        [[ -n $obfs ]] && printf 'obfs=%s\nobfs_password=%s\n' "$obfs" "$obfspw"
        [[ -n $tls_meta ]] && printf '%s\n' "$tls_meta"
        printf 'created=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } | node_write "$name"
    ok "已添加 Hysteria2 节点：${name} (${port}/udp, SNI ${sni})"
}

node_add_anytls() {
    local name port sni pw certmode acme_domain=''
    name=$(_node_ask_name "$(_node_default_name 'anytls')") || die '节点名称无效'
    port=$(_node_ask_port tcp 8444) || die '端口不可用'
    pw=$(pget password '')
    [[ -z $pw ]] && pw=$(gen_password)
    certmode=$(_node_ask_cert_mode)

    if [[ $certmode == acme ]]; then
        acme_domain=$(domain_choose) || die 'ACME 域名无效，节点未创建'
        sni=$acme_domain
    else
        sni=$(_node_ask_cert_name "$(sbox_public_addr 2>/dev/null || printf '127.0.0.1')") || die '证书名称无效，节点未创建'
    fi

    local tls_meta=''
    if [[ $certmode != none ]]; then
        tls_meta=$(_node_prepare_tls "$name" "$certmode" "$sni" "$acme_domain") \
            || die "证书准备失败（模式：${certmode}），节点未创建"
    fi

    {
        cat <<EOF
name=$name
type=anytls
port=$port
listen=::
sni=$sni
password=$pw
tls_mode=$certmode
EOF
        [[ -n $tls_meta ]] && printf '%s\n' "$tls_meta"
        printf 'created=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } | node_write "$name"
    ok "已添加 AnyTLS 节点：${name} (${port}/tcp, SNI ${sni})"
}

node_add_tuic() {
    local name port sni uuid pw congestion relay certmode acme_domain=''
    name=$(_node_ask_name "$(_node_default_name 'tuic')") || die '节点名称无效'
    port=$(_node_ask_port udp 8443) || die '端口不可用'
    uuid=$(pget uuid '')
    [[ -z $uuid ]] && uuid=$(gen_uuid)
    valid_uuid "$uuid" || die "UUID 不合法"
    pw=$(pget password '')
    [[ -z $pw ]] && pw=$(gen_password)
    congestion=$(pget congestion 'bbr')
    relay=$(pget udp_relay_mode 'native')
    certmode=$(_node_ask_cert_mode)

    if [[ $certmode == acme ]]; then
        acme_domain=$(domain_choose) || die 'ACME 域名无效，节点未创建'
        sni=$acme_domain
    else
        sni=$(_node_ask_cert_name "$(sbox_public_addr 2>/dev/null || printf '127.0.0.1')") || die '证书名称无效，节点未创建'
    fi

    local tls_meta=''
    if [[ $certmode != none ]]; then
        tls_meta=$(_node_prepare_tls "$name" "$certmode" "$sni" "$acme_domain") \
            || die "证书准备失败（模式：${certmode}），节点未创建"
    fi

    {
        cat <<EOF
name=$name
type=tuic
port=$port
listen=::
sni=$sni
uuid=$uuid
password=$pw
congestion=$congestion
udp_relay_mode=$relay
tls_mode=$certmode
EOF
        [[ -n $tls_meta ]] && printf '%s\n' "$tls_meta"
        printf 'created=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } | node_write "$name"
    ok "已添加 TUIC 节点：${name} (${port}/udp, SNI ${sni})"
}

node_add() { # node_add <protocol>
    local proto=${1:-}
    [[ -n $proto ]] || die "请指定协议：vless | hysteria2 | anytls | tuic"
    case $proto in
        vless | reality | vless-reality | vless-reality-vision) node_add_vless ;;
        hysteria2 | hy2) node_add_hysteria2 ;;
        anytls) node_add_anytls ;;
        tuic | tuic5) node_add_tuic ;;
        *) die "不支持的协议：$proto" ;;
    esac
}

# ────────────────────────── 删除 / 修改 ──────────────────────────
# ────────────────────────── 证书 ──────────────────────────
node_regen_cert() { # node_regen_cert <name>
    local name=$1 mode sni
    node_exists "$name" || die "节点 ${name} 不存在"
    mode=$(node_meta "$name" tls_mode)
    sni=$(node_meta "$name" sni)
    case $mode in
        selfsigned)
            tls_generate_selfsigned "$name" "$sni"
            config_apply
            ;;
        reality) info "Reality 节点不需要证书（借用 ${sni} 的握手）" ;;
        acme)
            domain=$(node_meta "$name" acme_domain)
            info "ACME 域名：${domain}"
            printf '  当前状态：%s\n' "$(tls_acme_status "$domain" 2>/dev/null)"
            if [[ -z $(tls_acme_cert "$domain" || true) ]]; then
                tls_wait_acme "$domain" 30 || true
            else
                ok "ACME 证书：$(tls_acme_status "$domain")"
            fi
            ;;
        manual) info "手动证书模式，请替换证书文件后执行 sbox apply" ;;
        none) info "该节点未启用 TLS" ;;
        *) warn "未知证书模式：${mode:-未设置}" ;;
    esac
}

node_cert_list() {
    local n mode sni domain
    for n in $(node_names); do
        mode=$(node_meta "$n" tls_mode)
        sni=$(node_meta "$n" sni)
        printf '  %s%-16s %-10s %s%s\n' "$C_BOLD" "$n" "$(tls_summary "$n")" "$sni" "$C_RESET"
        if [[ $mode == acme ]]; then
            domain=$(node_meta "$n" acme_domain)
            printf '    %sACME 域名：%s  状态：%s%s\n' "$C_GREY" "$domain" \
                "$(tls_acme_status "$domain" 2>/dev/null)" "$C_RESET"
        elif tls_cert_exists "$n"; then
            printf '    %s到期：%s  SAN：%s%s\n' "$C_GREY" \
                "$(openssl x509 -in "$(tls_cert_dir "$n")/cert.pem" -noout -enddate 2>/dev/null | cut -d= -f2)" \
                "$(openssl x509 -in "$(tls_cert_dir "$n")/cert.pem" -noout -ext subjectAltName 2>/dev/null | tail -1 | tr -d ' ')" \
                "$C_RESET"
        fi
    done
}

node_del() { # node_del <name> [--force]
    local name=$1 force=${2:-}
    node_exists "$name" || die "节点 ${name} 不存在"
    if [[ $force != '--force' ]] && ! confirm "确认删除节点 ${name}？"; then
        info "已取消"
        return 0
    fi
    local port proto
    port=$(node_meta "$name" port)
    proto=$(node_port_proto "$name")
    rm -f "$(node_file "$name")"
    rm -rf "$(tls_cert_dir "$name")"
    sys_firewall_close "$port" "$proto"

    ok "已删除节点 ${name}"
    local remain
    remain=$(node_count)
    if [[ ${remain:-0} -gt 0 ]]; then
        config_apply
    else
        info "已无节点，清空服务端配置"
        service_stop_singbox || true
        printf '{\n  "log": { "level": "warn" },\n  "inbounds": [],\n  "outbounds": [ { "type": "direct", "tag": "direct" } ]\n}\n' >"$SBOX_SERVER_JSON"
    fi
}

# ────────────────────────── 修改 ──────────────────────────
node_apply_port() { # <name> <port>
    local name=$1 port=$2 proto old
    proto=$(node_port_proto "$name")
    old=$(node_meta "$name" port)
    valid_port "$port" || die "端口不合法：${port}"
    [[ $port == "$old" ]] && { info '端口未变化'; return 0; }
    node_port_taken "$port" "$proto" "$name" && die "端口 ${port}/${proto} 已被其它节点占用"
    sys_firewall_close "$old" "$proto"
    node_meta_set "$name" port "$port"
    sys_firewall_open "$port" "$proto"
    ok "端口 ${old} → ${port}/${proto}"
}

node_apply_secret() { # <name> [uuid|password]
    local name=$1 value=${2:-} type
    type=$(node_type "$name")
    if [[ $type == vless ]]; then
        value=${value:-$(gen_uuid)}
        valid_uuid "$value" || die "UUID 不合法：$value"
        node_meta_set "$name" uuid "$value"
        ok "UUID 已更新：${value}"
    else
        value=${value:-$(gen_password)}
        [[ -n $value ]] || die '密码不能为空'
        node_meta_set "$name" password "$value"
        ok "密码已更新：${value}"
    fi
}

node_apply_sni() { # <name> <sni>
    local name=$1 sni=$2
    valid_ip_or_host "$sni" || die "SNI 不合法：${sni}"
    node_meta_set "$name" sni "$sni"
    ok "SNI 已更新为 ${sni}"
}

node_apply_addr() { # <name> <addr>
    local name=$1 addr=${2:-}
    node_meta_set "$name" addr "$addr"
    if [[ -n $addr ]]; then ok "链路地址已设置为 ${addr}"; else ok '链路地址已恢复自动探测'; fi
}

node_apply_acme() { # <name> <domain> [email]
    local name=$1 domain=$2 email=${3:-}
    valid_domain "$domain" \
        || die "ACME 域名不合法：${domain}（需要真实域名，不能是 IP 或伪装站点）"
    domain_record "$domain" "$email"
    node_meta_set "$name" tls_mode acme
    node_meta_set "$name" acme_domain "$domain"
    [[ -n $email ]] && node_meta_set "$name" acme_email "$email"
    node_meta_set "$name" sni "$domain"
    if domain_has_cert "$domain"; then
        ok "已切换为 ACME：${domain}（复用已有证书：$(domain_status_text "$domain")）"
    else
        ok "已切换为 ACME：${domain}（需解析到本机，80/443 可达）"
    fi
}

node_apply_selfsigned() { # <name>
    local name=$1
    node_meta_set "$name" tls_mode selfsigned
    tls_generate_selfsigned "$name" "$(node_meta "$name" sni)"
    ok '已切换为自签证书'
}

node_regen_key() { # <name>：Reality 重新生成密钥对 / 其它协议重新生成证书
    local name=$1 type kp priv pub
    type=$(node_type "$name")
    if [[ $type == vless ]]; then
        kp=$("$(sbox_singbox_path)" generate reality-keypair 2>/dev/null) || die '生成 Reality 密钥失败'
        priv=$(awk -F': ' '/PrivateKey/ {print $2; exit}' <<<"$kp")
        pub=$(awk -F': ' '/PublicKey/ {print $2; exit}' <<<"$kp")
        node_meta_set "$name" reality_private "$priv"
        node_meta_set "$name" reality_public "$pub"
        ok 'Reality 密钥已重新生成（客户端需更新链接）'
    else
        tls_generate_selfsigned "$name" "$(node_meta "$name" sni)"
    fi
}

node_edit() { # node_edit <name> [--port P|--sni S|--uuid U|--password W|--addr A|--regen-key]
    local name=$1 type
    node_exists "$name" || die "节点 ${name} 不存在"
    type=$(node_type "$name")

    # 非交互模式：只要带了任一参数就直接应用，便于脚本化运维
    if [[ -n ${ARGS[port]:-}${ARGS[uuid]:-}${ARGS[password]:-}${ARGS[sni]:-}${ARGS[addr]:-}${ARGS[acme-domain]:-} ]] \
        || [[ ${ARGS[regen-key]:-0} == 1 || ${ARGS[selfsigned]:-0} == 1 ]]; then
        [[ -n ${ARGS[port]:-} ]] && node_apply_port "$name" "${ARGS[port]}"
        [[ -n ${ARGS[uuid]:-}${ARGS[password]:-} ]] \
            && node_apply_secret "$name" "${ARGS[uuid]:-${ARGS[password]:-}}"
        [[ -n ${ARGS[sni]:-} ]] && node_apply_sni "$name" "${ARGS[sni]}"
        [[ -n ${ARGS[addr]:-} ]] && node_apply_addr "$name" "${ARGS[addr]}"
        [[ -n ${ARGS[acme-domain]:-} ]] \
            && node_apply_acme "$name" "${ARGS[acme-domain]}" "${ARGS[acme-email]:-}"
        [[ ${ARGS[selfsigned]:-0} == 1 ]] && node_apply_selfsigned "$name"
        [[ ${ARGS[regen-key]:-0} == 1 ]] && node_regen_key "$name"
        config_apply
        return 0
    fi

    printf '\n'
    ui_title "修改节点 ${name}（$(node_proto_label "$type")）"
    ui_menu_item 1 '端口' "$(node_meta "$name" port)"
    ui_menu_item 2 '密码 / UUID'
    ui_menu_item 3 'SNI / 伪装域名'
    ui_menu_item 4 '链路地址（生成链接时使用的 server）' "$(node_meta "$name" addr)"
    if [[ $type == vless ]]; then
        ui_menu_item 5 '重新生成 Reality 密钥'
    else
        ui_menu_item 5 '重新生成自签证书'
    fi
    ui_menu_item 6 '重新生成密码 / UUID'
    ui_menu_item 7 '证书方式（自签 / ACME / 手动）' "$(tls_summary "$name")"
    ui_menu_item 0 '返回'

    local c port sni addr
    c=$(ask '请选择' '0')
    case $c in
        1)
            port=$(ask "新端口（当前 $(node_meta "$name" port)）" "$(node_meta "$name" port)")
            node_apply_port "$name" "$port"
            ;;
        2)
            if [[ $type == vless ]]; then
                node_apply_secret "$name" "$(ask '新 UUID（回车自动生成）' "$(gen_uuid)")"
            else
                node_apply_secret "$name" "$(ask '新密码（回车自动生成）' "$(gen_password)")"
            fi
            ;;
        3)
            sni=$(ask 'SNI' "$(node_meta "$name" sni)")
            node_apply_sni "$name" "$sni"
            ;;
        4)
            addr=$(ask '链路地址（留空表示自动探测）' "$(node_meta "$name" addr)")
            node_apply_addr "$name" "$addr"
            ;;
        5) node_regen_key "$name" ;;
        6) node_apply_secret "$name" '' ;;
        7)
            if [[ $type == vless ]]; then
                warn 'Reality 节点不使用证书，无需切换'
            else
                local m cf kf
                m=$(ask '证书方式 1=自签 2=ACME 3=手动' '1')
                case $m in
                    2)
                        node_apply_acme "$name" \
                            "$(ask 'ACME 域名（必须解析到本机）' '')" \
                            "$(ask 'ACME 邮箱（可留空）' '')"
                        ;;
                    3)
                        cf=$(ask '证书文件路径' "$(node_meta "$name" cert_file)")
                        kf=$(ask '私钥文件路径' "$(node_meta "$name" key_file)")
                        node_meta_set "$name" tls_mode manual
                        node_meta_set "$name" cert_file "$cf"
                        node_meta_set "$name" key_file "$kf"
                        ok '已切换为手动证书'
                        ;;
                    *) node_apply_selfsigned "$name" ;;
                esac
            fi
            ;;
        0 | '') return 0 ;;
        *) warn '无效选择'; return 0 ;;
    esac
    config_apply
}

# ────────────────────────── 展示 ──────────────────────────
node_table() {
    local names
    names=$(node_names)
    if [[ -z $names ]]; then
        ui_note '尚无节点，可从主菜单「添加节点」开始'
        return 0
    fi
    local rows=() n type port proto addr tls
    for n in $names; do
        type=$(node_type "$n")
        port=$(node_meta "$n" port)
        proto=$(node_port_proto "$n")
        addr=$(node_addr "$n")
        tls=$(tls_summary "$n")
        rows+=("${n}"$'\t'"$(node_proto_label "$type")"$'\t'"${port}/${proto}"$'\t'"${addr}"$'\t'"${tls}")
    done
    ui_table '16 16 10 18 10' "名称"$'\t'"协议"$'\t'"端口"$'\t'"地址"$'\t'"证书" "${rows[@]}"
}

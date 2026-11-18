# shellcheck shell=bash
# tls.sh — 证书管理：自签证书 / ACME 自动签发 / 手动证书

if [[ -n ${SBOX_TLS_SH:-} ]]; then return 0; fi
readonly SBOX_TLS_SH=1

# tls_cert_dir <节点名>
tls_cert_dir() { printf '%s/%s' "$SBOX_CERTS_DIR" "$1"; }

# tls_generate_selfsigned <节点名> <SNI|IP>：生成 ECDSA P-256 自签证书
tls_generate_selfsigned() {
    local name=$1 sni=$2 dir key cert san
    dir=$(tls_cert_dir "$name")
    key=$dir/key.pem
    cert=$dir/cert.pem

    # 支持以 IP 作为证书主体（无域名场景）
    if [[ $sni =~ ^[0-9]+\.?[0-9.]*$ || $sni =~ ^[0-9a-fA-F:]+$ ]]; then
        san="IP:${sni},DNS:localhost"
    else
        san="DNS:${sni},DNS:localhost"
    fi

    mkdir -p "$dir"
    if id "$SBOX_USER" >/dev/null 2>&1; then
        chown "root:${SBOX_USER}" "$dir" 2>/dev/null || true
        chmod 750 "$dir"
    else
        chmod 700 "$dir"
    fi

    if ! openssl ecparam -genkey -name prime256v1 -out "$key" 2>/dev/null; then
        die "生成私钥失败（openssl 不可用？）"
    fi
    openssl req -new -x509 -days 3650 -key "$key" -out "$cert" -sha256 \
        -subj "/CN=${sni}" \
        -addext "subjectAltName=${san}" \
        -addext "basicConstraints=critical,CA:FALSE" \
        -addext "keyUsage=critical,digitalSignature,keyEncipherment" \
        -addext "extendedKeyUsage=serverAuth" 2>/dev/null \
        || die "生成自签证书失败"
    chmod 600 "$key" "$cert"
    sbox_chown_ro "$key"
    sbox_chown_ro "$cert"
    ok "已生成自签证书（SNI: ${sni}）"
}

# tls_cert_exists <节点名>
tls_cert_exists() {
    local dir
    dir=$(tls_cert_dir "$1")
    [[ -r $dir/cert.pem && -r $dir/key.pem ]]
}

# tls_show <节点名>：打印证书摘要
tls_show() {
    local name=$1 dir
    dir=$(tls_cert_dir "$name")
    [[ -r $dir/cert.pem ]] || { warn "节点 ${name} 无本地证书文件"; return 1; }
    openssl x509 -in "$dir/cert.pem" -noout \
        -subject -issuer -dates -ext subjectAltName 2>/dev/null \
        | sed 's/^/    /'
}

# tls_fingerprint_sha256 <节点名>：证书 DER 的 SHA256（可用于客户端证书固定）
tls_fingerprint_sha256() {
    local cert
    cert=$(tls_cert_dir "$1")/cert.pem
    [[ -r $cert ]] || return 1
    openssl x509 -in "$cert" -outform der -noout 2>/dev/null | sha256sum | awk '{print $1}'
}

# ACME 证书文件（certmagic 默认落盘：<data_dir>/certificates/<issuer>/<domain>/<domain>.crt）
tls_acme_cert() { # <domain>
    local domain=${1:-} f
    [[ -n $domain ]] || return 1
    f=$(find "$SBOX_STATE/acme" -type f -name '*.crt' 2>/dev/null | grep -F "/${domain}/" | head -1)
    if [[ -n $f ]]; then printf '%s' "$f"; return 0; fi
    # 兜底：按证书 SAN 匹配（防止 certmagic 目录布局变化）
    while IFS= read -r f; do
        [[ -n $f ]] || continue
        if openssl x509 -in "$f" -noout -ext subjectAltName 2>/dev/null | grep -q "DNS:${domain}"; then
            printf '%s' "$f"
            return 0
        fi
    done < <(find "$SBOX_STATE/acme" -type f -name '*.crt' 2>/dev/null)
    return 1
}

tls_acme_status() { # <domain> → 已签发（到期…）/未签发
    local domain=$1 f
    f=$(tls_acme_cert "$domain") || true
    if [[ -z $f ]]; then
        printf '未签发'
        return 0
    fi
    printf '已签发（%s）' "$(openssl x509 -in "$f" -noout -enddate 2>/dev/null | cut -d= -f2)"
}

# 等待 ACME 签发（交互场景给用户即时反馈）
tls_wait_acme() { # <domain> [超时秒]
    local domain=$1 timeout=${2:-60} waited=0 f
    info "等待 ACME 为 ${domain} 签发证书（最多 ${timeout}s）…"
    while ((waited < timeout)); do
        if f=$(tls_acme_cert "$domain"); then
            ok "ACME 证书已签发：${f}（到期 $(openssl x509 -in "$f" -noout -enddate 2>/dev/null | cut -d= -f2)）"
            return 0
        fi
        sleep 3
        waited=$((waited + 3))
    done
    warn "ACME 仍未签发。常见原因：域名未解析到本机 / 80 或 443 不可达 / 被 CDN 代理"
    info "查看服务日志：sbox log 80"
    return 1
}

# tls_summary <节点名>：节点列表用的简短说明
tls_summary() {
    local name=$1 mode domain
    mode=$(node_meta "$name" tls_mode)
    case $mode in
        selfsigned)
            if tls_cert_exists "$name"; then printf '自签'; else printf '自签(缺失)'; fi ;;
        acme)
            domain=$(node_meta "$name" acme_domain)
            if [[ -n $(tls_acme_cert "$domain" || true) ]]; then
                printf 'ACME✓'
            else
                printf 'ACME…'
            fi ;;
        manual) printf '手动证书' ;;
        reality) printf 'Reality' ;;
        none) printf '无TLS' ;;
        *) printf '%s' "${mode:-未设置}" ;;
    esac
}

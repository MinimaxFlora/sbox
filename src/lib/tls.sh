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

# tls_summary <节点名>：节点列表用的简短说明
tls_summary() {
    local name=$1 mode
    mode=$(node_meta "$name" tls_mode)
    case $mode in
        selfsigned)
            if tls_cert_exists "$name"; then printf '自签'; else printf '自签(缺失)'; fi ;;
        acme) printf 'ACME' ;;
        manual) printf '手动证书' ;;
        reality) printf 'Reality' ;;
        none) printf '无TLS' ;;
        *) printf '%s' "${mode:-未设置}" ;;
    esac
}

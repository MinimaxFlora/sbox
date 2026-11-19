# shellcheck shell=bash
# domain.sh — ACME 域名库
#
# 一个域名只申请一次证书；多个节点（AnyTLS / Hysteria2 / TUIC）复用同一张证书。
# 域名库同时记录节点里引用过的域名与手工登记的域名，证书状态直接从 certmagic 落盘读取。

if [[ -n ${SBOX_DOMAIN_SH:-} ]]; then return 0; fi
readonly SBOX_DOMAIN_SH=1

domain_file() { printf '%s/%s.conf' "$SBOX_DOMAINS_DIR" "$1"; }

domain_field() { # <domain> <KEY>
    local f
    f=$(domain_file "$1")
    [[ -r $f ]] || return 0
    sed -n "s/^${2}=//p" "$f" 2>/dev/null | head -1
}

# 已知域名 = 节点引用的 ∪ 域名库登记的
domain_all() {
    local f d
    {
        for f in "$SBOX_NODES_DIR"/*.meta; do
            [[ -e $f ]] || continue
            d=$(node_meta "$(basename "$f" .meta)" acme_domain)
            [[ -n $d ]] && printf '%s\n' "$d"
        done
        for f in "$SBOX_DOMAINS_DIR"/*.conf; do
            [[ -e $f ]] || continue
            basename "$f" .conf
        done
    } | sort -u
}

domain_node_count() { # <domain>
    local f n=0 d
    for f in "$SBOX_NODES_DIR"/*.meta; do
        [[ -e $f ]] || continue
        d=$(node_meta "$(basename "$f" .meta)" acme_domain)
        [[ $d == "$1" ]] && n=$((n + 1))
    done
    printf '%s' "$n"
}

domain_has_cert() { [[ -n $(tls_acme_cert "${1:-}" || true) ]]; }

domain_expiry_epoch() { # <domain> → 证书到期 unix 时间
    local cert
    cert=$(tls_acme_cert "$1" || true)
    [[ -n $cert ]] || return 1
    date -d "$(openssl x509 -in "$cert" -noout -enddate 2>/dev/null | cut -d= -f2)" +%s 2>/dev/null
}

domain_days_left() { # <domain> → 剩余天数
    local e now
    e=$(domain_expiry_epoch "$1") || return 1
    now=$(date +%s)
    printf '%s' $(((e - now) / 86400))
}

domain_status_text() { # <domain>
    local cert e days
    cert=$(tls_acme_cert "$1" || true)
    if [[ -z $cert ]]; then
        printf '未签发（apply 后由 sing-box 申请）'
        return 0
    fi
    e=$(domain_expiry_epoch "$1") || { printf '已签发'; return 0; }
    days=$(((e - $(date +%s)) / 86400))
    if ((days < 0)); then
        printf '已过期（%s）' "$(date -d "@$e" +%F 2>/dev/null)"
    elif ((days < 30)); then
        printf '已签发，%s 到期（剩 %s 天，等待自动续期）' "$(date -d "@$e" +%F 2>/dev/null)" "$days"
    else
        printf '已签发，%s 到期（剩 %s 天）' "$(date -d "@$e" +%F 2>/dev/null)" "$days"
    fi
}

domain_record() { # <domain> [email]
    local domain=${1:-} email=${2:-} f first
    valid_domain "$domain" || die "域名不合法：${domain}（需要真实域名，不能是 IP 或伪装站点）"
    mkdir -p "$SBOX_DOMAINS_DIR"
    f=$(domain_file "$domain")
    if [[ -r $f ]]; then
        first=$(domain_field "$domain" ADDED_AT)
        [[ -n $email ]] || email=$(domain_field "$domain" EMAIL)
    else
        first=$(date +%F)
    fi
    {
        printf 'DOMAIN=%s\n' "$domain"
        printf 'EMAIL=%s\n' "$email"
        printf 'ADDED_AT=%s\n' "$first"
    } >"$f"
    sbox_chown_ro "$f" 2>/dev/null || true
}

domain_forget() { # 仅删除登记，不动证书文件
    rm -f "$(domain_file "$1")"
}

# 新域名：交互输入 + 登记；已有证书则提示复用
domain_new_interactive() {
    local d email
    d=$(pget acme_domain '')
    [[ -z $d ]] && d=$(pget domain '')
    if [[ -z $d && -t 0 ]]; then
        d=$(ask 'ACME 域名（必须已解析到本机，如 node.example.com）' '')
    fi
    [[ -n $d ]] || die 'ACME 模式必须指定域名：--acme-domain your.domain'
    valid_domain "$d" || die "域名不合法：${d}（需要真实域名，不能是 IP 或伪装站点）"
    if domain_has_cert "$d"; then
        info "域名 ${d} 已有证书，直接复用（不会重复申请）"
    fi
    email=$(pget acme_email '')
    if [[ -z $email ]]; then
        email=$(domain_field "$d" EMAIL)
    fi
    if [[ -z $email && -t 0 ]]; then
        email=$(ask 'ACME 账号邮箱（可留空）' '')
    fi
    domain_record "$d" "$email"
    printf '%s' "$d"
}

# 节点选域名：--acme-domain > 交互选择已有域名 / 申请新域名 > 非交互复用第一张证书
domain_choose() {
    local want sel list=() i=1 d
    want=$(pget acme_domain '')
    [[ -z $want ]] && want=$(pget domain '')
    if [[ -n $want ]]; then
        valid_domain "$want" || die "域名不合法：${want}（需要真实域名，不能是 IP 或伪装站点）"
        domain_record "$want" "$(pget acme_email '')"
        if domain_has_cert "$want"; then
            info "复用已签发证书：${want}（$(domain_status_text "$want")）"
        elif (($(domain_node_count "$want") > 0)); then
            info "复用域名：${want}（证书申请中）"
        fi
        printf '%s' "$want"
        return 0
    fi

    mapfile -t list < <(domain_all)
    if ((${#list[@]} == 0)); then
        domain_new_interactive
        return 0
    fi

    if [[ ! -t 0 ]]; then
        printf '%s' "${list[0]}"
        return 0
    fi

    printf '\n  %s已有证书域名（可复用，不会重复申请）%s\n' "$C_BOLD" "$C_RESET" >&2
    for d in "${list[@]}"; do
        printf '   %s%d)%s %-30s %s\n' "$C_BOLD" "$i" "$C_RESET" "$d" "$(domain_status_text "$d")" >&2
        i=$((i + 1))
    done
    printf '   %s0)%s 申请新的域名（需要 DNS 已解析到本机、80/443 可达）\n' "$C_BOLD" "$C_RESET" >&2
    sel=$(ask '选择（0=申请新域名）' '1')
    if [[ $sel == 0 ]]; then
        domain_new_interactive
        return 0
    fi
    if ! is_uint "$sel" || ((sel < 1 || sel > ${#list[@]})); then
        warn "无效选择：${sel}，使用第一个域名 ${list[0]}"
        sel=1
    fi
    d=${list[$((sel - 1))]}
    domain_record "$d" "$(domain_field "$d" EMAIL)"
    printf '%s' "$d"
}

# 手动触发一次续期检查（certmagic 在到期前 30 天自动续期，这里只重启服务并报告结果）
domain_renew() { # <domain>
    local d=${1:-} before after
    [[ -n $d ]] || die '用法：sbox domain renew <域名>'
    domain_node_count "$d" >/dev/null
    before=$(domain_expiry_epoch "$d" 2>/dev/null || true)
    info "重启 sing-box 触发证书检查：${d}"
    service_restart_singbox >/dev/null 2>&1 || true
    sleep 5
    after=$(domain_expiry_epoch "$d" 2>/dev/null || true)
    if [[ -z $after ]]; then
        warn "仍未获得证书：${d}（检查 DNS 解析与 80/443 可达）"
        service_log 20 2>/dev/null | grep -iE 'acme|error' | tail -5 || true
        return 1
    fi
    if [[ -n $before && $after != "$before" ]]; then
        ok "证书已更新：${d}（$(domain_status_text "$d")）"
    else
        ok "证书有效：${d}（$(domain_status_text "$d")）"
    fi
}

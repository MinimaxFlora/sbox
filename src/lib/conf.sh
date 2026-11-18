# shellcheck shell=bash
# conf.sh — 全局配置 /etc/sbox/sbox.conf 读写

if [[ -n ${SBOX_CONF_SH:-} ]]; then return 0; fi
readonly SBOX_CONF_SH=1

# 默认配置（首次安装时写入）
conf_write_defaults() {
    mkdir -p "$SBOX_ETC"
    if [[ -s $SBOX_CONF ]]; then return 0; fi
    local token addr sub_port
    token=$(rand_hex 16)
    addr=${SBOX_ADDR_HINT:-}
    if [[ -z $addr ]]; then
        addr=$(sys_public_ipv4 2>/dev/null || sys_public_ipv6 2>/dev/null || true)
    fi
    sub_port=${SBOX_SUB_PORT_DEFAULT}
    cat >"$SBOX_CONF" <<EOF
# sbox 全局配置 — 修改后执行 sbox apply 生效
# 对外访问地址（生成节点链接/订阅时使用，留空则自动探测）
ADDR=${addr}
# 订阅服务监听
SUB_PORT=${sub_port}
SUB_BIND=${SBOX_SUB_BIND_DEFAULT}
# 订阅令牌（访问 /<token>/singbox 等路径）
SUB_TOKEN=${token}
# 订阅基本认证（留空则不启用）
SUB_USER=
SUB_PASS=
# sing-box 版本通道：stable / testing
CHANNEL=stable
# 节点默认伪装站点 / Reality 目标
REALITY_SNI=${SBOX_REALITY_SNI_DEFAULT}
TLS_SNI=${SBOX_TLS_SNI_DEFAULT}
MASQUERADE=${SBOX_MASQUERADE_DEFAULT}
EOF
    sbox_chown_ro "$SBOX_CONF"
    ok "已生成全局配置：$SBOX_CONF"
}

conf_get() { # conf_get <键> <默认值>
    local key=$1 def=${2:-} val=''
    if [[ -r $SBOX_CONF ]]; then
        val=$(awk -v k="$key" 'index($0, k "=") == 1 { sub(/^[^=]*=/, ""); print; exit }' "$SBOX_CONF")
    fi
    [[ -n $val ]] && printf '%s' "$val" || printf '%s' "$def"
}

conf_set() { # conf_set <键> <值>
    local key=$1 val=$2
    [[ -f $SBOX_CONF ]] || : >"$SBOX_CONF"
    if grep -q "^${key}=" "$SBOX_CONF" 2>/dev/null; then
        # 使用 awk 重写，避免值中的斜杠破坏 sed
        awk -v k="$key" -v v="$val" '
            index($0, k "=") == 1 { print k "=" v; next }
            { print }
        ' "$SBOX_CONF" >"$SBOX_CONF.tmp" && mv "$SBOX_CONF.tmp" "$SBOX_CONF"
    else
        printf '%s=%s\n' "$key" "$val" >>"$SBOX_CONF"
    fi
    sbox_chown_ro "$SBOX_CONF"
}

conf_load() {
    SBOX_ADDR=$(conf_get ADDR '')
    SBOX_SUB_PORT=$(conf_get SUB_PORT "$SBOX_SUB_PORT_DEFAULT")
    SBOX_SUB_BIND=$(conf_get SUB_BIND "$SBOX_SUB_BIND_DEFAULT")
    SBOX_SUB_TOKEN=$(conf_get SUB_TOKEN '')
    SBOX_SUB_USER=$(conf_get SUB_USER '')
    SBOX_SUB_PASS=$(conf_get SUB_PASS '')
    SBOX_CHANNEL=$(conf_get CHANNEL 'stable')
    SBOX_REALITY_SNI=$(conf_get REALITY_SNI "$SBOX_REALITY_SNI_DEFAULT")
    SBOX_TLS_SNI=$(conf_get TLS_SNI "$SBOX_TLS_SNI_DEFAULT")
    SBOX_MASQUERADE=$(conf_get MASQUERADE "$SBOX_MASQUERADE_DEFAULT")

    if [[ -z $SBOX_SUB_TOKEN ]]; then
        SBOX_SUB_TOKEN=$(rand_hex 16)
        conf_set SUB_TOKEN "$SBOX_SUB_TOKEN"
    fi
    return 0
}

# 服务端的对外地址：配置优先，其次自动探测（结果缓存到 state）
sbox_public_addr() {
    local addr
    addr=$(conf_get ADDR '')
    if [[ -n $addr ]]; then printf '%s' "$addr"; return 0; fi
    if [[ -r $SBOX_STATE_FILE ]]; then
        addr=$(sed -n 's/^addr=//p' "$SBOX_STATE_FILE" | head -1)
        if [[ -n $addr ]]; then printf '%s' "$addr"; return 0; fi
    fi
    addr=$(sys_public_ipv4 2>/dev/null || sys_public_ipv6 2>/dev/null || true)
    if [[ -n $addr ]]; then
        mkdir -p "$SBOX_ETC"; : >>"$SBOX_STATE_FILE"; chmod 600 "$SBOX_STATE_FILE"
        if grep -q '^addr=' "$SBOX_STATE_FILE" 2>/dev/null; then
            sed -i "s|^addr=.*|addr=$addr|" "$SBOX_STATE_FILE"
        else
            printf 'addr=%s\n' "$addr" >>"$SBOX_STATE_FILE"
        fi
        printf '%s' "$addr"
        return 0
    fi
    return 1
}

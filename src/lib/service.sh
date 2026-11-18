# shellcheck shell=bash
# service.sh — systemd 服务单元、用户、权限与生命周期

if [[ -n ${SBOX_SERVICE_SH:-} ]]; then return 0; fi
readonly SBOX_SERVICE_SH=1

readonly SBOX_UNIT_DIR=${SBOX_UNIT_DIR:-/etc/systemd/system}

# 创建无登录权限的系统用户
service_ensure_user() {
    if id "$SBOX_USER" >/dev/null 2>&1; then return 0; fi
    if command -v useradd >/dev/null 2>&1; then
        useradd --system --no-create-home --shell /usr/sbin/nologin \
            --home-dir "$SBOX_STATE" "$SBOX_USER" 2>/dev/null \
            || useradd -r -s /sbin/nologin -d "$SBOX_STATE" "$SBOX_USER"
    elif command -v adduser >/dev/null 2>&1; then
        adduser -S -H -s /sbin/nologin -h "$SBOX_STATE" "$SBOX_USER" >/dev/null
    fi
    id "$SBOX_USER" >/dev/null 2>&1 || die "创建系统用户 ${SBOX_USER} 失败"
    debug "已创建系统用户 ${SBOX_USER}"
}

# 权限收紧：配置/证书对服务用户只读，元数据不对普通用户开放
service_fix_perms() {
    local f
    chmod 750 "$SBOX_ETC" 2>/dev/null || true
    chown "root:${SBOX_USER}" "$SBOX_ETC" 2>/dev/null || true
    mkdir -p "$SBOX_NODES_DIR" "$SBOX_CERTS_DIR" "$SBOX_SUB_DIR" "$SBOX_STATE"
    chown -R "root:${SBOX_USER}" "$SBOX_NODES_DIR" "$SBOX_CERTS_DIR" 2>/dev/null || true
    chmod 750 "$SBOX_NODES_DIR" "$SBOX_CERTS_DIR" "$SBOX_SUB_DIR" 2>/dev/null || true
    find "$SBOX_NODES_DIR" -type f -exec chmod 640 {} \; 2>/dev/null || true
    find "$SBOX_CERTS_DIR" -type f -exec chmod 640 {} \; 2>/dev/null || true
    find "$SBOX_CERTS_DIR" -mindepth 1 -type d -exec chmod 750 {} \; 2>/dev/null || true
    for f in "$SBOX_CONF" "$SBOX_STATE_FILE" "$SBOX_SERVER_JSON"; do
        [[ -f $f ]] || continue
        chown "root:${SBOX_USER}" "$f" 2>/dev/null || true
        chmod 640 "$f"
    done
    # ACME 数据目录必须由服务用户可写（证书/账号缓存在这里）
    mkdir -p "$SBOX_STATE/acme"
    chown -R "${SBOX_USER}:${SBOX_USER}" "$SBOX_STATE/acme" 2>/dev/null || true
    chmod 750 "$SBOX_STATE/acme" 2>/dev/null || true
    chown "${SBOX_USER}:${SBOX_USER}" "$SBOX_STATE" 2>/dev/null || true
    chmod 750 "$SBOX_STATE" 2>/dev/null || true
}

# 写入 sing-box 单元
service_write_singbox_unit() {
    mkdir -p "$SBOX_UNIT_DIR"
    cat >"$SBOX_UNIT_DIR/${SBOX_SINGBOX_SERVICE}.service" <<EOF
[Unit]
Description=sing-box proxy server (managed by sbox)
Documentation=https://sing-box.sagernet.org
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
User=${SBOX_USER}
Group=${SBOX_USER}
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_NETLINK AF_UNIX
RestrictNamespaces=true
LockPersonality=true
MemoryDenyWriteExecute=true
ReadWritePaths=${SBOX_STATE}
ExecStart=/usr/local/bin/sing-box -c ${SBOX_SERVER_JSON} run
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=5s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "$SBOX_UNIT_DIR/${SBOX_SINGBOX_SERVICE}.service"
}

# 写入订阅服务单元
service_write_sub_unit() {
    local py
    py=$(command -v python3 || true)
    [[ -n $py ]] || return 1
    cat >"$SBOX_UNIT_DIR/${SBOX_SUB_SERVICE}.service" <<EOF
[Unit]
Description=sbox subscription server
Documentation=${SBOX_SELF_URL}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${SBOX_USER}
Group=${SBOX_USER}
Environment=SBOX_ROOT=${SBOX_ROOT}
Environment=SBOX_ETC=${SBOX_ETC}
Environment=SBOX_STATE=${SBOX_STATE}
Environment=SBOX_BIN=${SBOX_BIN}
ExecStart=${py} ${SBOX_ROOT}/src/subserver/sbox-sub.py
Restart=on-failure
RestartSec=5s
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectControlGroups=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_NETLINK AF_UNIX
ReadWritePaths=${SBOX_STATE}

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "$SBOX_UNIT_DIR/${SBOX_SUB_SERVICE}.service"
}

service_install_units() {
    sys_need_systemd
    service_ensure_user
    service_write_singbox_unit
    service_write_sub_unit || warn "python3 缺失，订阅服务单元未安装"
    systemctl daemon-reload
}

service_start_singbox() { systemctl start "$SBOX_SINGBOX_SERVICE" 2>/dev/null; }
service_stop_singbox() { systemctl stop "$SBOX_SINGBOX_SERVICE" 2>/dev/null; }

service_restart_singbox() {
    if ! systemctl is-enabled --quiet "$SBOX_SINGBOX_SERVICE" 2>/dev/null; then
        systemctl enable "$SBOX_SINGBOX_SERVICE" >/dev/null 2>&1 || true
    fi
    systemctl restart "$SBOX_SINGBOX_SERVICE"
}

service_enable_singbox() { systemctl enable --now "$SBOX_SINGBOX_SERVICE" >/dev/null 2>&1 || systemctl enable "$SBOX_SINGBOX_SERVICE" >/dev/null 2>&1 && systemctl start "$SBOX_SINGBOX_SERVICE" >/dev/null 2>&1; }

service_active_singbox() { systemctl is-active --quiet "$SBOX_SINGBOX_SERVICE" 2>/dev/null; }
service_active_sub() { systemctl is-active --quiet "$SBOX_SUB_SERVICE" 2>/dev/null; }

service_start_sub() {
    systemctl enable --now "$SBOX_SUB_SERVICE" >/dev/null 2>&1 || {
        systemctl enable "$SBOX_SUB_SERVICE" >/dev/null 2>&1 || true
        systemctl start "$SBOX_SUB_SERVICE" >/dev/null 2>&1 || true
    }
}

service_restart_sub() { systemctl restart "$SBOX_SUB_SERVICE" 2>/dev/null || true; }

service_log() { # service_log [行数]
    local lines=${1:-40}
    systemctl status "$SBOX_SINGBOX_SERVICE" --no-pager -n "$lines" 2>&1 | sed 's/^/  /'
}

service_status_summary() {
    local sb_state sub_state
    if service_active_singbox; then sb_state=$(ui_state running); else sb_state=$(ui_state stopped); fi
    if service_active_sub; then sub_state=$(ui_state running); else sub_state=$(ui_state stopped); fi
    ui_kv 'sing-box' "$sb_state"
    ui_kv '订阅服务' "$sub_state"
}

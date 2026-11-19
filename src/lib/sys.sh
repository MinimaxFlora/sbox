# shellcheck shell=bash
# sys.sh — 系统探测、依赖安装、网络下载、端口与防火墙

if [[ -n ${SBOX_SYS_SH:-} ]]; then return 0; fi
readonly SBOX_SYS_SH=1

# ── 系统信息 ──
sys_os_id() {
    local id='unknown'
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        id=$(. /etc/os-release 2>/dev/null; echo "${ID:-unknown}")
    fi
    printf '%s' "$id"
}

sys_os_name() {
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        (. /etc/os-release 2>/dev/null; printf '%s' "${PRETTY_NAME:-${NAME:-Linux}}")
    else
        printf 'Linux'
    fi
}

sys_pkg_manager() {
    local id
    id=$(sys_os_id)
    case $id in
        ubuntu | debian | raspbian | kali) printf 'apt' ;;
        alpine) printf 'apk' ;;
        fedora | rhel | centos | rocky | almalinux | openEuler) printf 'dnf' ;;
        arch | manjaro) printf 'pacman' ;;
        opensuse* | sles) printf 'zypper' ;;
        *) for c in apt-get dnf yum apk pacman zypper; do
                command -v "$c" >/dev/null 2>&1 && { printf '%s' "$c"; return; }
            done
            printf 'none' ;;
    esac
}

sys_arch() { # 输出 sing-box 资产后缀
    local m
    m=$(uname -m)
    case $m in
        x86_64 | amd64) printf 'amd64' ;;
        aarch64 | arm64) printf 'arm64' ;;
        armv7l | armv7) printf 'armv7' ;;
        armv6l | armv6) printf 'armv6' ;;
        i386 | i686) printf '386' ;;
        riscv64) printf 'riscv64' ;;
        loongarch64) printf 'loong64' ;;
        *) die "不支持的架构：$m" ;;
    esac
}

sys_init() { # systemd / openrc / none
    if [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null 2>&1; then
        printf 'systemd'
    elif command -v rc-service >/dev/null 2>&1; then
        printf 'openrc'
    else
        printf 'none'
    fi
}

sys_need_systemd() {
    [[ $(sys_init) == systemd ]] || die "当前系统未运行 systemd，sbox 需要 systemd 管理服务"
}

# ── 依赖 ──
sys_have() { command -v "$1" >/dev/null 2>&1; }

sys_install_pkgs() { # sys_install_pkgs <包名...>
    local pm pkgs=("$@")
    ((${#pkgs[@]})) || return 0
    pm=$(sys_pkg_manager)
    case $pm in
        apt) DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 || true
             DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${pkgs[@]}" >/dev/null 2>&1 ;;
        apk) apk add --no-cache "${pkgs[@]}" >/dev/null 2>&1 ;;
        dnf | yum) "$pm" install -y -q "${pkgs[@]}" >/dev/null 2>&1 ;;
        pacman) pacman -Sy --noconfirm "${pkgs[@]}" >/dev/null 2>&1 ;;
        zypper) zypper -q install -y "${pkgs[@]}" >/dev/null 2>&1 ;;
        *) return 1 ;;
    esac
}

sys_ensure_deps() { # 必需：curl / tar / openssl；可选：python3（订阅服务）
    local missing=() p
    for p in curl tar openssl; do
        sys_have "$p" || missing+=("$p")
    done
    if ((${#missing[@]})); then
        info "安装依赖：${missing[*]}"
        sys_install_pkgs "${missing[@]}" || die "依赖安装失败，请手动安装：${missing[*]}"
    fi
    if ! sys_have python3; then
        info "安装 python3（订阅服务需要）"
        case $(sys_pkg_manager) in
            apk) sys_install_pkgs python3 || warn "python3 安装失败，订阅服务将不可用" ;;
            *) sys_install_pkgs python3 || warn "python3 安装失败，订阅服务将不可用" ;;
        esac
    fi
    return 0
}

# ── 下载 ──
# sys_download <url> <输出文件>：带重试、超时与失败清理
sys_download() {
    local url=$1 out=$2 tries=${3:-3} i
    for ((i = 1; i <= tries; i++)); do
        if curl -fsSL --connect-timeout 10 --max-time 180 --retry 2 \
            -H 'User-Agent: sbox-installer' -o "$out" "$url" 2>/dev/null; then
            [[ -s $out ]] && return 0
        fi
        [[ $i -lt $tries ]] && { warn "下载失败，${i}/${tries} 重试：$url"; sleep $((i * 2)); }
    done
    rm -f "$out"
    return 1
}

# sys_download_gh <github 路径> <输出文件>：直连 + 镜像回退
sys_download_gh() {
    local path=$1 out=$2 mirror=${SBOX_GH_MIRROR:-}
    local urls=("https://github.com/$path")
    if [[ -n $mirror ]]; then
        urls=("${mirror%/}/https://github.com/$path" "https://github.com/$path")
    fi
    local u
    for u in "${urls[@]}"; do
        sys_download "$u" "$out" 2 && return 0
    done
    return 1
}

# ── 端口 ──
sys_port_free() { # sys_port_free <端口> <tcp|udp>
    local port=$1 proto=${2:-tcp}
    if [[ $proto == udp ]]; then
        ! ss -Huan 2>/dev/null | awk '{print $4}' | grep -q ":$port\$"
    else
        ! ss -Htan 2>/dev/null | awk '{print $4}' | grep -q ":$port\$"
    fi
}

sys_find_port() { # sys_find_port <起始端口> <tcp|udp> [上限]
    local p=${1:-10000} proto=${2:-tcp} limit=${3:-65535}
    while ((p <= limit)); do
        if sys_port_free "$p" "$proto"; then printf '%s' "$p"; return 0; fi
        ((p++))
    done
    return 1
}

# 申请端口时避开已配置节点使用的端口
sys_alloc_port() { # sys_alloc_port <协议类型> <tcp|udp> <首选端口>
    local proto=$2 preferred=${3:-}
    local used
    used=$(node_used_ports)
    if [[ -n $preferred ]] && valid_port "$preferred" && ! grep -qx "$preferred" <<<"$used" \
        && sys_port_free "$preferred" "$proto"; then
        printf '%s' "$preferred"
        return 0
    fi
    local start=443
    [[ $proto == udp ]] && start=443
    local p
    for p in $(seq "$start" 65535); do
        ((p == 22 || p == 80 || p == 2087)) && continue
        if ! grep -qx "$p" <<<"$used" && sys_port_free "$p" "$proto"; then
            printf '%s' "$p"
            return 0
        fi
    done
    return 1
}

# ── 地址 ──
sys_public_ipv4() {
    local r
    for u in https://api.ipify.org https://ifconfig.me/ip https://ipv4.icanhazip.com; do
        r=$(curl -fsS -m 8 "$u" 2>/dev/null | tr -d '[:space:]')
        [[ $r =~ ^[0-9.]+$ ]] && { printf '%s' "$r"; return 0; }
    done
    return 1
}

sys_public_ipv6() {
    local r
    for u in https://ipv6.icanhazip.com https://api64.ipify.org; do
        r=$(curl -fsS -m 8 "$u" 2>/dev/null | tr -d '[:space:]')
        [[ $r =~ ^[0-9a-fA-F:.]+$ ]] && { printf '%s' "$r"; return 0; }
    done
    return 1
}

# ── 防火墙 ──
sys_firewall_open() { # sys_firewall_open <端口> <tcp|udp>
    local port=$1 proto=$2
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'Status: active'; then
        ufw allow "$port/$proto" >/dev/null 2>&1 && debug "ufw 放行 $port/$proto"
    elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        firewall-cmd --permanent --add-port="$port/$proto" >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
        debug "firewalld 放行 $port/$proto"
    elif command -v nft >/dev/null 2>&1 && nft list ruleset 2>/dev/null | grep -q .; then
        # 仅在已有 nft 规则且未放行时追加，避免影响无防火墙的系统
        nft add rule inet filter input "$proto" dport "$port" accept >/dev/null 2>&1 || true
        debug "nftables 放行 $port/$proto"
    fi
    return 0
}

sys_firewall_close() { # sys_firewall_close <端口> <tcp|udp>
    local port=$1 proto=$2
    if command -v ufw >/dev/null 2>&1; then
        ufw delete allow "$port/$proto" >/dev/null 2>&1 || true
    elif command -v firewall-cmd >/dev/null 2>&1; then
        firewall-cmd --permanent --remove-port="$port/$proto" >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
    fi
    return 0
}

# BBR
sys_bbr() {
    local cc
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)
    printf '%s' "$cc"
}

sys_enable_bbr() {
    if [[ $(sys_bbr) == bbr ]]; then
        ok "BBR 已启用（$(sys_bbr)）"
        return 0
    fi
    # 内核模块（部分镜像未自动加载）
    modprobe tcp_bbr >/dev/null 2>&1 || true
    printf 'net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr\n' \
        >/etc/sysctl.d/99-sbox-bbr.conf
    chmod 644 /etc/sysctl.d/99-sbox-bbr.conf
    # 逐项写入并立即生效（容器化环境 sysctl -p 可能整体失败）
    sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1 || true
    sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1 || true
    sysctl -p /etc/sysctl.d/99-sbox-bbr.conf >/dev/null 2>&1 || true

    local cc
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)
    if [[ $cc == bbr ]]; then
        ok 'BBR 已启用（重启后仍生效：/etc/sysctl.d/99-sbox-bbr.conf）'
    else
        warn "BBR 未生效（当前 ${cc}），请确认内核支持 bbr 或容器有 sysctl 权限"
        return 1
    fi
}

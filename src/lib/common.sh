# shellcheck shell=bash
# common.sh — 常量、日志、终端着色、校验与通用工具函数
# 所有函数均为幂等纯函数，被 sbox.sh 与各模块 source。

if [[ -n ${SBOX_COMMON_SH:-} ]]; then return 0; fi
readonly SBOX_COMMON_SH=1

# ─────────────────────────── 路径与常量 ───────────────────────────
SBOX_NAME=${SBOX_NAME:-sbox}
SBOX_USER=${SBOX_USER:-sbox}
SBOX_ROOT=${SBOX_ROOT:-/usr/local/lib/sbox}
SBOX_BIN=${SBOX_BIN:-/usr/local/bin/sbox}
SBOX_ETC=${SBOX_ETC:-/etc/sbox}
SBOX_STATE=${SBOX_STATE:-/var/lib/sbox}
SBOX_NODES_DIR=${SBOX_NODES_DIR:-$SBOX_ETC/nodes}
SBOX_CERTS_DIR=${SBOX_CERTS_DIR:-$SBOX_ETC/certs}
SBOX_SUB_DIR=${SBOX_SUB_DIR:-$SBOX_ETC/sub}
SBOX_CONF=${SBOX_CONF:-$SBOX_ETC/sbox.conf}
SBOX_SERVER_JSON=${SBOX_SERVER_JSON:-$SBOX_ETC/config.json}
SBOX_VERSIONS_DIR=${SBOX_VERSIONS_DIR:-$SBOX_ROOT/versions}
SBOX_STATE_FILE=${SBOX_STATE_FILE:-$SBOX_ETC/state}

SBOX_SINGBOX_SERVICE=${SBOX_SINGBOX_SERVICE:-sing-box}
SBOX_SUB_SERVICE=${SBOX_SUB_SERVICE:-sbox-sub}
SBOX_SUB_PORT_DEFAULT=${SBOX_SUB_PORT_DEFAULT:-2087}
SBOX_SUB_BIND_DEFAULT=${SBOX_SUB_BIND_DEFAULT:-0.0.0.0}
SBOX_REALITY_SNI_DEFAULT=${SBOX_REALITY_SNI_DEFAULT:-www.microsoft.com}
SBOX_MASQUERADE_DEFAULT=${SBOX_MASQUERADE_DEFAULT:-https://www.bing.com}
SBOX_GH_API=${SBOX_GH_API:-https://api.github.com}
SBOX_GH_REPO=${SBOX_GH_REPO:-SagerNet/sing-box}
SBOX_SELF_URL=${SBOX_SELF_URL:-https://github.com/MinimaxFlora/sbox}

# 支持的协议标识（节点文件 name 存 type 字段）
readonly SBOX_PROTOCOLS="vless hysteria2 anytls tuic"

# ─────────────────────────── 终端着色 ───────────────────────────
if [[ -t 1 && -z ${NO_COLOR:-} ]]; then
    readonly C_RESET=$'\033[0m'
    readonly C_BOLD=$'\033[1m'
    readonly C_DIM=$'\033[2m'
    readonly C_RED=$'\033[31m'
    readonly C_GREEN=$'\033[32m'
    readonly C_YELLOW=$'\033[33m'
    readonly C_BLUE=$'\033[34m'
    readonly C_MAGENTA=$'\033[35m'
    readonly C_CYAN=$'\033[36m'
    readonly C_GREY=$'\033[90m'
else
    readonly C_RESET='' C_BOLD='' C_DIM='' C_RED='' C_GREEN='' C_YELLOW=''
    readonly C_BLUE='' C_MAGENTA='' C_CYAN='' C_GREY=''
fi

# ─────────────────────────── 日志 ───────────────────────────
_sbox_log() { # _sbox_log <icon> <color> <message>
    printf '  %s%s%s %s\n' "$2" "$1" "$C_RESET" "$3" >&2
}

log()  { _sbox_log '·' "$C_CYAN"  "$*"; }
info() { _sbox_log '·' "$C_GREY"  "$*"; }
ok()   { _sbox_log '✓' "$C_GREEN" "$*"; }
warn() { _sbox_log '!' "$C_YELLOW" "$*"; }
err()  { _sbox_log '✗' "$C_RED"   "$*"; }
die()  { SBOX_DYING=1; err "$*"; exit 1; }

debug() {
    [[ ${SBOX_DEBUG:-0} == 1 ]] || return 0
    printf '%s[debug] %s%s\n' "$C_GREY" "$*" "$C_RESET" >&2
}

# ERR trap：报告出错行号与命令，便于运维排查（die 已输出明确原因，不重复报告）
sbox_err_trap() {
    local exit_code=$1 line=$2 cmd=$3
    (( ${SBOX_DYING:-0} == 1 )) && return 0
    err "执行失败（退出码 ${exit_code}）：行 ${line}: ${cmd}"
}

# ─────────────────────────── 交互 ───────────────────────────
is_tty() { [[ -t 0 ]]; }

# confirm <提示> [默认 y/N]
confirm() {
    local prompt=$1 def=${2:-n} reply
    # --yes：一律视为同意
    if [[ ${SBOX_ASSUME_YES:-0} == 1 ]]; then
        return 0
    fi
    if [[ ! -t 0 ]]; then
        [[ $def == y ]]
        return
    fi
    if [[ $def == y ]]; then
        read -r -p "  ${prompt} [Y/n] " reply || return 1
        [[ -z $reply || $reply == [Yy]* ]]
    else
        read -r -p "  ${prompt} [y/N] " reply || return 1
        [[ $reply == [Yy]* ]]
    fi
}

# ask <提示> [默认值] → 输出用户输入（空则默认值）
ask() {
    local prompt=$1 def=${2:-} reply
    if [[ -t 0 ]]; then
        if [[ -n $def ]]; then
            read -r -p "  ${prompt} [${def}]: " reply || reply=''
        else
            read -r -p "  ${prompt}: " reply || reply=''
        fi
        [[ -z $reply ]] && reply=$def
    else
        reply=$def
    fi
    printf '%s' "$reply"
}

# pause：等待回车（非交互环境直接返回）
pause() {
    [[ -t 0 ]] || return 0
    read -r -p "  ${C_GREY}按回车返回${C_RESET} " _ || true
}

# ─────────────────────────── 校验 ───────────────────────────
valid_port() {
    [[ ${1:-} =~ ^[0-9]+$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535))
}

valid_port_name() { # 端口名称合法性（用于 tag）
    [[ ${1:-} =~ ^[0-9]+$ ]]
}

valid_name() { # 节点名：字母数字下划线中划线，1-32
    [[ ${1:-} =~ ^[A-Za-z0-9_-]{1,32}$ ]]
}

valid_uuid() {
    [[ ${1:-} =~ ^[0-9A-Fa-f]{4}[0-9A-Fa-f]{4}-[0-9A-Fa-f]{2}-[0-9A-Fa-f]{2}-[0-9A-Fa-f]{2}-[0-9A-Fa-f]{6}$ \
        || ${1:-} =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]]
}

valid_ip_or_host() {
    local v=${1:-}
    [[ -n $v && $v != *[[:space:]]* && $v =~ ^[A-Za-z0-9._:-]+$ ]]
}

# 域名校验（ACME 必须使用真实域名，不能是 IP 或伪装站点）
valid_domain() {
    local d=${1:-}
    [[ -n $d && $d != *[[:space:]]* ]] || return 1
    [[ $d =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]] || return 1
    [[ $d == *..* ]] && return 1
    # 排除 IP（如 1.2.3.4 会被上面的正则误判为域名）
    [[ $d =~ ^[0-9.]+$ ]] && return 1
    return 0
}

# ─────────────────────────── 随机与编码 ───────────────────────────
rand_hex() { # rand_hex <字节数>
    local n=${1:-16}
    if [[ -r /dev/urandom ]]; then
        od -An -N"$n" -tx1 /dev/urandom | tr -d ' \n'
    else
        openssl rand -hex "$n"
    fi
}

gen_uuid() { # 优先使用 sing-box 自带生成器，保证与官方一致
    local sb
    if sb=$(sbox_singbox_path) && [[ -x $sb ]]; then
        "$sb" generate uuid && return 0
    fi
    if [[ -r /proc/sys/kernel/random/uuid ]]; then
        cat /proc/sys/kernel/random/uuid && return 0
    fi
    local h
    h=$(rand_hex 16)
    printf '%s-%s-%s-%s-%s' "${h:0:4}" "${h:4:4}" "${h:8:4}" "${h:12:4}" "${h:16:4}"
}

gen_password() { # 可打印、无引号冲突的强随机密码
    local raw
    raw=$(rand_hex 24)
    printf '%s' "${raw}"
}

gen_short_id() {
    rand_hex 4   # reality short_id 最长 8 字节，4 字节足够且兼容客户端
}

# URL 百分号编码（共享链接中的密码/UUID/名称）
urlencode() {
    local s=${1:-} out='' c i
    for ((i = 0; i < ${#s}; i++)); do
        c=${s:i:1}
        case $c in
            [A-Za-z0-9._~-]) out+=$c ;;
            *) printf -v c '%%%02X' "'$c"; out+=$c ;;
        esac
    done
    printf '%s' "$out"
}

# JSON 字符串转义（写入值必须经过此函数）
json_escape() {
    local s=${1:-}
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//$'\n'/\\n}
    s=${s//$'\r'/\\r}
    s=${s//$'\t'/\\t}
    printf '%s' "$s"
}

# YAML 标量（mihomo 配置用）：安全字符直接输出，其余加单引号
yaml_scalar() {
    local s=${1:-}
    if [[ -n $s ]] && printf '%s' "$s" | grep -Eq '^[A-Za-z0-9._:/?#=&+@%*-]+$'; then
        printf '%s' "$s"
    else
        s=${s//\'/\'\'}
        printf "'%s'" "$s"
    fi
}

b64() { # 标准 base64，无换行
    if command -v base64 >/dev/null 2>&1; then
        base64 | tr -d '\n'
    else
        printf '%s' "$*" | openssl base64 -A
    fi
}

# ─────────────────────────── 显示宽度（中文对齐） ───────────────────────────
# disp_width <字符串> → 终端显示宽度（CJK 计 2 列）
disp_width() {
    local s=$1
    if command -v python3 >/dev/null 2>&1; then
        python3 - "$s" <<'PY'
import sys, unicodedata
s = sys.argv[1]
w = sum(2 if unicodedata.east_asian_width(c) in ('W', 'F') else 1 for c in s)
print(w)
PY
        return
    fi
    # 回退：每个非 ASCII 字符按 2 列估算
    local ascii_len wide_len
    ascii_len=$(printf '%s' "$s" | LC_ALL=C tr -d '\200-\377' | wc -c | tr -d ' ')
    wide_len=$(printf '%s' "$s" | LC_ALL=C tr -cd '\200-\377' | wc -c | tr -d ' ')
    printf '%s' "$((ascii_len + wide_len / 2))"
}

# pad_c <字符串> <宽度>：左对齐补空格
pad_c() {
    local s=$1 w=$2 cur
    cur=$(disp_width "$s")
    ((cur < w)) && printf -v 's' '%s%*s' "$s" "$((w - cur))" ''
    printf '%s' "$s"
}

# pad_r <字符串> <宽度>：右对齐补空格
pad_r() {
    local s=$1 w=$2 cur
    cur=$(disp_width "$s")
    ((cur < w)) && printf -v 's' '%*s%s' "$((w - cur))" '' "$s"
    printf '%s' "$s"
}

# ─────────────────────────── 杂项 ───────────────────────────
need_root() {
    [[ ${EUID:-$(id -u)} -eq 0 ]] || die "需要 root 权限，请使用 sudo 运行"
}

sbox_script_version() {
    local f=${SBOX_ROOT}/VERSION
    if [[ -r $f ]]; then
        head -1 "$f" | tr -d '[:space:]'
    else
        printf 'dev'
    fi
}

trim() {
    local s=$1
    s=${s#"${s%%[![:space:]]*}"}
    s=${s%"${s##*[![:space:]]}"}
    printf '%s' "$s"
}

is_uint() { [[ ${1:-} =~ ^[0-9]+$ ]]; }

# 把文件设为「服务用户只读」（root 可写）：服务（sing-box / 订阅）以非 root 运行
sbox_chown_ro() {
    local f=$1
    [[ -e $f ]] || return 0
    if id "$SBOX_USER" >/dev/null 2>&1; then
        chown "root:${SBOX_USER}" "$f" 2>/dev/null || true
        chmod 640 "$f"
    else
        chmod 600 "$f"
    fi
}

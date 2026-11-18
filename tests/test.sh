#!/usr/bin/env bash
# tests/test.sh — 本地 / CI 自动化测试
#
# 覆盖：语法检查、shellcheck、节点生成、服务端配置校验、
#       客户端配置（sing-box / mihomo）校验、分享链接格式、订阅服务接口。
#
# 依赖：bash 4.2+、openssl；可选 sing-box / mihomo 二进制（缺失则跳过对应校验）。

set -Eeuo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
SKIP=0

pass() { PASS=$((PASS + 1)); printf '  \033[32m✓\033[0m %s\n' "$*"; }
fail() { FAIL=$((FAIL + 1)); printf '  \033[31m✗\033[0m %s\n' "$*"; }
skip() { SKIP=$((SKIP + 1)); printf '  \033[33m-\033[0m %s\n' "$*"; }

# run_step <描述> <函数> [参数...]：在子 shell 中执行，die 不会中断测试
run_step() {
    local desc=$1
    shift
    if ("$@") >"$TMP/step.log" 2>&1; then
        pass "$desc"
    else
        fail "$desc"
        sed 's/^/      /' "$TMP/step.log" 2>/dev/null | head -10
    fi
}

# expect_fail <描述> <函数> [参数...]：期望失败（die 不会中断测试）
expect_fail() {
    local desc=$1
    shift
    if ("$@") >"$TMP/step.log" 2>&1; then
        fail "$desc"
    else
        pass "$desc"
    fi
}

# ── 隔离环境 ──
export SBOX_ROOT=$ROOT
export SBOX_ETC=$TMP/etc
export SBOX_STATE=$TMP/state
export SBOX_VERSIONS_DIR=$TMP/versions
export SBOX_NODES_DIR=$TMP/etc/nodes
export SBOX_CERTS_DIR=$TMP/etc/certs
export SBOX_SUB_DIR=$TMP/etc/sub
export SBOX_CONF=$TMP/etc/sbox.conf
export SBOX_SERVER_JSON=$TMP/etc/config.json
export SBOX_STATE_FILE=$TMP/etc/state
export SB_LINK=$TMP/bin/sing-box
declare -A ARGS=()
POSITIONAL=()
mkdir -p "$SBOX_ETC" "$SBOX_NODES_DIR" "$SBOX_STATE" "$TMP/bin"

# ── 载入库 ──
# shellcheck source=../src/lib/common.sh
source "$ROOT/src/lib/common.sh"
# shellcheck source=../src/lib/ui.sh
source "$ROOT/src/lib/ui.sh"
# shellcheck source=../src/lib/sys.sh
source "$ROOT/src/lib/sys.sh"
# shellcheck source=../src/lib/conf.sh
source "$ROOT/src/lib/conf.sh"
# shellcheck source=../src/lib/version.sh
source "$ROOT/src/lib/version.sh"
# shellcheck source=../src/lib/tls.sh
source "$ROOT/src/lib/tls.sh"
# shellcheck source=../src/lib/node.sh
source "$ROOT/src/lib/node.sh"
# shellcheck source=../src/lib/render.sh
source "$ROOT/src/lib/render.sh"
# shellcheck source=../src/lib/link.sh
source "$ROOT/src/lib/link.sh"
# shellcheck source=../src/lib/sub.sh
source "$ROOT/src/lib/sub.sh"

SINGBOX=${SINGBOX_BIN:-}
if [[ -z $SINGBOX ]] && command -v sing-box >/dev/null 2>&1; then SINGBOX=$(command -v sing-box); fi
MIHOMO=${MIHOMO_BIN:-}
if [[ -z $MIHOMO ]] && command -v mihomo >/dev/null 2>&1; then MIHOMO=$(command -v mihomo); fi

# 转为绝对路径：SB_LINK 是指向二进制的软链，相对路径会失效
if [[ -n $SINGBOX && $SINGBOX != /* ]]; then
    SINGBOX="$(cd "$(dirname "$SINGBOX")" && pwd)/$(basename "$SINGBOX")"
fi
if [[ -n $MIHOMO && $MIHOMO != /* ]]; then
    MIHOMO="$(cd "$(dirname "$MIHOMO")" && pwd)/$(basename "$MIHOMO")"
fi

printf '\n\033[1msbox 测试套件\033[0m\n'

# ── 1. 语法 ──
for f in "$ROOT"/sbox.sh "$ROOT"/install.sh "$ROOT"/src/lib/*.sh; do
    if bash -n "$f" 2>/dev/null; then pass "语法正常：${f#"$ROOT"/}"; else fail "语法错误：$f"; fi
done
if bash -n "$ROOT/src/subserver/sbox-sub.py" 2>/dev/null; then skip 'py 文件不参与 bash 语法检查'; fi
if python3 -m py_compile "$ROOT/src/subserver/sbox-sub.py" 2>/dev/null; then
    pass 'Python 订阅服务可编译'
else
    fail 'Python 订阅服务编译失败'
fi

# ── 2. shellcheck ──
if command -v shellcheck >/dev/null 2>&1; then
    if shellcheck -x --severity=warning "$ROOT"/sbox.sh "$ROOT"/install.sh "$ROOT"/src/lib/*.sh; then
        pass 'shellcheck 通过'
    else
        fail 'shellcheck 发现问题'
    fi
else
    skip 'shellcheck 未安装'
fi

# ── 3. 纯函数 ──
if [[ $(sb_asset_name v1.14.4) == "sing-box-1.14.4-linux-$(sys_arch).tar.gz" ]]; then
    pass 'sing-box 资产名生成正确'
else
    fail "sing-box 资产名错误：$(sb_asset_name v1.14.4)"
fi
[[ $(urlencode 'a b/c+d') == 'a%20b%2Fc%2Bd' ]] && pass 'URL 编码正确' || fail 'URL 编码错误'
[[ $(json_escape 'a"b\c') == 'a\"b\\c' ]] && pass 'JSON 转义正确' || fail 'JSON 转义错误'
valid_uuid "123e4567-e89b-12d3-a456-426614174000" && pass 'UUID 校验正确' || fail 'UUID 校验错误'
valid_uuid "not-a-uuid" && fail 'UUID 校验漏判' || pass 'UUID 非法值被拒绝'

# ── 4. 安装二进制（测试用） ──
if [[ -n $SINGBOX && -x $SINGBOX ]]; then
    ln -sfn "$SINGBOX" "$SB_LINK"
elif [[ $(sys_arch) == amd64 || $(sys_arch) == arm64 ]]; then
    tag=$(sb_remote_tag stable 2>/dev/null || true)
    if [[ -n $tag ]] && sb_install_version "$tag" >/dev/null 2>&1; then
        ln -sfn "$SBOX_VERSIONS_DIR/$tag/sing-box" "$SB_LINK"
        pass "下载并安装 sing-box ${tag}（测试用）"
    else
        skip '无法下载 sing-box，跳过配置校验'
    fi
else
    skip '无可用 sing-box 二进制'
fi

# ── 5. 节点与配置 ──
conf_write_defaults >/dev/null 2>&1 || true
conf_set ADDR 127.0.0.1
conf_load

ARGS=([name]=vless-test [port]=24443 [sni]=www.microsoft.com)
run_step '创建 VLESS Reality 节点' node_add_vless
ARGS=([name]=hy2-test [port]=24444 [sni]=example.com [cert]=selfsigned [password]=TestPass123)
run_step '创建 Hysteria2 节点' node_add_hysteria2
ARGS=([name]=anytls-test [port]=24445 [sni]=example.com [cert]=selfsigned [password]=TestPass456)
run_step '创建 AnyTLS 节点' node_add_anytls
ARGS=([name]=tuic-test [port]=24446 [sni]=example.com [cert]=selfsigned [password]=TestPass789)
run_step '创建 TUIC 节点' node_add_tuic

# Hysteria2 + salamander obfs（验证 --obfs-password 参数解析）
ARGS=([name]=hy2-obfs [port]=24447 [sni]=example.com [cert]=selfsigned
      [password]=TestPassObfs [obfs]=salamander [obfs-password]=ObfsPass123)
run_step '创建 Hysteria2 obfs 节点' node_add_hysteria2

# ACME 节点：必须显式域名；1.14 生成 certificate_provider 而不是 legacy acme
ARGS=([name]=acme-test [port]=24448 [sni]=acme.example.com [cert]=acme
      [password]=TestPassAcme [acme-domain]=acme.example.com [acme-email]=admin@example.com)
run_step '创建 ACME(AnyTLS) 节点' node_add_anytls
ARGS=([name]=acme-bad [port]=24449 [cert]=acme [password]=x)
expect_fail 'ACME 缺少域名被拒绝' node_add_anytls
[[ ! -f $SBOX_NODES_DIR/acme-bad.meta ]] && pass '失败的 ACME 节点未落盘' || fail '失败的 ACME 节点残留'

[[ $(node_count) == 6 ]] && pass '节点数量为 6' || fail "节点数量异常：$(node_count)"

# IP 证书（无域名场景）：SAN 必须是 IP Address
run_step '生成 IP 自签证书' tls_generate_selfsigned ip-cert-test 127.0.0.1
if openssl x509 -in "$SBOX_CERTS_DIR/ip-cert-test/cert.pem" -noout -text 2>/dev/null | grep -q 'IP Address:127.0.0.1'; then
    pass '证书包含 IP SAN'
else
    fail '证书缺少 IP SAN'
fi
rm -rf "$SBOX_CERTS_DIR/ip-cert-test"

run_step '生成服务端配置' render_server_config "$SBOX_SERVER_JSON"
grep -q '"certificate_provider": { "type": "acme"' "$SBOX_SERVER_JSON" \
    && pass 'ACME 使用 1.14 certificate_provider（非 legacy acme）' || fail 'ACME 字段不是 1.14 格式'
if python3 -c 'import json,sys
d=json.load(open(sys.argv[1]))
tls=[i["tls"] for i in d["inbounds"] if i.get("tag")=="anytls-acme-test"][0]
ok = "certificate_path" not in tls and "key_path" not in tls and tls["server_name"]=="acme.example.com"
sys.exit(0 if ok else 1)' "$SBOX_SERVER_JSON"; then
    pass 'ACME 节点不写 certificate_path/key_path'
else
    fail 'ACME 节点仍带 certificate_path/key_path'
fi
if [[ -n $(sb_current_bin) ]]; then
    if config_validate "$SBOX_SERVER_JSON"; then pass 'sing-box check 通过（服务端）'; else fail 'sing-box check 失败（服务端）'; fi
else
    skip '无 sing-box，跳过服务端校验'
fi

# ── 6. 客户端配置 ──
render_client_singbox >"$TMP/client.json" 2>"$TMP/client.err"
if [[ -s $TMP/client.json ]]; then
    pass '生成 sing-box 客户端配置'
    if [[ -n $(sb_current_bin) ]]; then
        if "$(sb_current_bin)" check -c "$TMP/client.json" >/dev/null 2>&1; then
            pass 'sing-box check 通过（客户端，1.12+ 新格式）'
            grep -q '"default_domain_resolver": "dns-cn"' "$TMP/client.json" \
                && pass '客户端配置使用 1.14 模板（字符串 resolver / urltest / selector）' \
                || fail '客户端配置缺少 1.14 模板字段'
        else
            fail 'sing-box check 失败（客户端）'
            "$(sb_current_bin)" check -c "$TMP/client.json" 2>&1 | sed 's/^/      /'
        fi
    else
        skip '无 sing-box，跳过客户端校验'
    fi
else
    fail '生成 sing-box 客户端配置失败'
fi

render_client_mihomo >"$TMP/mihomo.yaml" 2>/dev/null
if [[ -s $TMP/mihomo.yaml ]]; then
    pass '生成 mihomo 配置'
    if [[ -n $MIHOMO && -x $MIHOMO ]]; then
        if "$MIHOMO" -t -f "$TMP/mihomo.yaml" >/dev/null 2>&1; then
            pass 'mihomo 配置校验通过'
        else
            fail 'mihomo 配置校验失败'
            "$MIHOMO" -t -f "$TMP/mihomo.yaml" 2>&1 | sed 's/^/      /'
        fi
    else
        skip '无 mihomo 二进制，跳过 mihomo 校验'
    fi
else
    fail '生成 mihomo 配置失败'
fi

# ── 7. 分享链接 ──
link_for_node vless-test | grep -q '^vless://.*flow=xtls-rprx-vision.*security=reality.*pbk=' \
    && pass 'VLESS Reality 链接格式正确' || fail 'VLESS Reality 链接格式错误'
link_for_node hy2-test | grep -q '^hysteria2://.*insecure=1' \
    && pass 'Hysteria2 链接格式正确' || fail 'Hysteria2 链接格式错误'
link_for_node anytls-test | grep -q '^anytls://.*alpn=h2' \
    && pass 'AnyTLS 链接格式正确' || fail 'AnyTLS 链接格式错误'
link_for_node tuic-test | grep -q '^tuic://.*congestion_control=bbr' \
    && pass 'TUIC 链接格式正确' || fail 'TUIC 链接格式错误'
# ACME 节点：SNI 必须是 ACME 域名，且不能再带 insecure=1
if link_for_node acme-test | grep -q 'sni=acme.example.com' && \
   link_for_node acme-test | grep -q 'insecure=0'; then
    pass 'ACME 链接 SNI=域名且 insecure=0'
else
    fail "ACME 链接错误：$(link_for_node acme-test)"
fi
[[ $(link_all | wc -l) == 6 ]] && pass '导出全部 6 条链接' || fail '链接数量错误'
link_all_b64 | base64 -d >/dev/null 2>&1 && pass 'Base64 订阅可解码' || fail 'Base64 订阅解码失败'

# ── 8. 订阅服务 ──
if command -v python3 >/dev/null 2>&1; then
    sub_port_use=24999
    sed -i "s|^SUB_PORT=.*|SUB_PORT=$sub_port_use|" "$SBOX_CONF"
    sed -i "s|^SUB_BIND=.*|SUB_BIND=127.0.0.1|" "$SBOX_CONF"
    export SBOX_BIN=$ROOT/sbox.sh
    python3 "$ROOT/src/subserver/sbox-sub.py" >"$TMP/sub.log" 2>&1 &
    sub_pid=$!
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        sleep 0.3
        curl -fsS -m 2 "http://127.0.0.1:$sub_port_use/health" >/dev/null 2>&1 && break
    done
    token=$(conf_get SUB_TOKEN)
    if curl -fsS -m 5 "http://127.0.0.1:$sub_port_use/$token/singbox" -o "$TMP/sub-singbox.json"; then
        pass '订阅接口 /singbox 返回内容'
        if [[ -n $SINGBOX ]]; then
            "$SINGBOX" check -c "$TMP/sub-singbox.json" >/dev/null 2>&1 \
                && pass '订阅返回的 sing-box 配置有效' || fail '订阅返回配置无效'
        fi
    else
        fail '订阅接口 /singbox 请求失败'
    fi
    curl -fsS -m 5 "http://127.0.0.1:$sub_port_use/$token/mihomo" -o "$TMP/sub-mihomo.yaml" \
        && pass '订阅接口 /mihomo 返回内容' || fail '订阅接口 /mihomo 请求失败'
    code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' "http://127.0.0.1:$sub_port_use/wrong-token/singbox" )
    [[ $code == 404 ]] && pass '错误令牌返回 404' || fail "错误令牌返回 $code"
    code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' -A 'clash-verge/1.0' "http://127.0.0.1:$sub_port_use/$token/auto")
    [[ $code == 200 ]] && pass 'UA 自动识别可用' || fail "UA 自动识别返回 $code"

    # Basic 认证（配置即时生效，无需重启）
    conf_set SUB_USER tester
    conf_set SUB_PASS secret123
    code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' "http://127.0.0.1:$sub_port_use/$token/singbox")
    [[ $code == 401 ]] && pass 'Basic 认证生效（无凭据 401）' || fail "无凭据返回 $code"
    code=$(curl -s -o /dev/null -m 5 -u tester:secret123 -w '%{http_code}' "http://127.0.0.1:$sub_port_use/$token/singbox")
    [[ $code == 200 ]] && pass 'Basic 认证通过（正确凭据 200）' || fail "正确凭据返回 $code"
    code=$(curl -s -o /dev/null -m 5 -u wrong:pw -w '%{http_code}' "http://127.0.0.1:$sub_port_use/$token/singbox")
    [[ $code == 401 ]] && pass '错误凭据被拒绝' || fail "错误凭据返回 $code"
    conf_set SUB_USER ''
    conf_set SUB_PASS ''
    code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' "http://127.0.0.1:$sub_port_use/$token/singbox")
    [[ $code == 200 ]] && pass '关闭认证后恢复开放' || fail "关闭认证后返回 $code"
    kill "$sub_pid" 2>/dev/null || true
    wait "$sub_pid" 2>/dev/null || true
else
    skip 'python3 缺失，跳过订阅服务测试'
fi

# ── 汇总 ──
printf '\n  通过 %d，失败 %d，跳过 %d\n\n' "$PASS" "$FAIL" "$SKIP"
((FAIL == 0)) || exit 1

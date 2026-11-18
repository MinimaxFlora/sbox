# 协议与配置：官方文档核对报告

核对对象：本仓库生成的全部 sing-box 配置（服务端 inbound、客户端 profile）与分享链接。
文档来源：`SagerNet/sing-box` 仓库 `testing` 分支的 `docs/configuration/`（对应 1.15 开发版文档）。
实测二进制：`v1.12.25`、`v1.13.21`、`v1.14.4`、`v1.15.0-alpha.13`；客户端对照 `mihomo v1.19.34`。

## 1. 服务端 inbound

### 1.1 VLESS + Reality Vision
文档：`configuration/inbound/vless/`、`configuration/shared/tls/#reality-fields`

| 我们生成 | 文档要求 | 结论 |
| --- | --- | --- |
| `users[].name` / `users[].uuid` | `users` 必填，`uuid` 必填 | ✓ |
| `users[].flow = "xtls-rprx-vision"` | 可用值仅 `xtls-rprx-vision` | ✓ |
| `tls.reality.handshake.{server,server_port}` | Server only、必填，值为 Dial Fields | ✓（借用 SNI 站点的 443） |
| `tls.reality.private_key` | Server only、必填 | ✓ |
| `tls.reality.short_id = ["xxxxxxxx"]` | 0–8 位十六进制 | ✓（4 字节 = 8 位十六进制） |
| `tls.server_name = <伪装域名>` | 用于证书/SNI 选择 | ✓ |
| `listen = "::"`, `listen_port` | Listen Fields | ✓ |

### 1.2 Hysteria2
文档：`configuration/inbound/hysteria2/`、`manual/proxy-protocol/hysteria2/`

| 我们生成 | 文档 | 结论 |
| --- | --- | --- |
| `users[].password` | 必填 | ✓ |
| `obfs.type = "salamander"` + `obfs.password` | 1.14 起支持 `salamander` / `gecko` | ✓（未用 1.14 新增 `gecko` 的 `min/max_packet_size`） |
| `masquerade = "https://..."` | string 或 object | ✓ |
| `tls.alpn = ["h3"]` | QUIC 需要 h3 ALPN | ✓ |
| 未设置 `up_mbps`/`down_mbps` | 空表示不限速 | ✓（配合 BBR） |
| 未设置 `bbr_profile`/`realm`/`brutal_debug` | 1.14 新增，可选 | 正常（不需要） |

### 1.3 AnyTLS（1.12+）
文档：`configuration/inbound/anytls/`、`configuration/outbound/anytls/`、协议原文 `anytls/anytls-go/docs/protocol.md`

| 我们生成 | 文档 | 结论 |
| --- | --- | --- |
| `users[].password` | 必填 | ✓ |
| `padding_scheme` 未设置 | 有默认 padding scheme | ✓ |
| `tls`（enabled + server_name + 证书/ACME） | 必填 | ✓ |
| `tls.alpn = ["h2"]` | 文档未规定 ALPN；协议原文亦未要求 | 属可选优化：与 mihomo 客户端默认 `alpn: h2` 对齐，双方一致即可 |

> 说明：AnyTLS 是 **TLS 承载**协议，必然需要证书与 `server_name`（SNI）。之前把伪装 SNI
> （`www.bing.com`）当成 ACME 域名是脚本 bug，不是协议不需要 SNI。

### 1.4 TUIC v5
文档：`configuration/inbound/tuic/`

| 我们生成 | 文档 | 结论 |
| --- | --- | --- |
| `users[].uuid` + `users[].password` | `uuid` 必填 | ✓ |
| `congestion_control = "bbr"` | `cubic`/`new_reno`/`bbr` | ✓ |
| `zero_rtt_handshake = false` | 文档明确建议关闭（重放攻击） | ✓ |
| `tls.alpn = ["h3"]` | QUIC 需要 h3 | ✓ |

## 2. TLS / 证书

文档：`configuration/shared/tls/`、`migration.md#migrate-inline-acme-to-certificate-provider`

| 模式 | 我们生成 | 版本门槛 |
| --- | --- | --- |
| 自签 | ECDSA P-256，SAN `DNS:<sni>` 或 `IP:<ip>`，10 年 | 全版本 |
| 手动 | `certificate_path` + `key_path` | 全版本 |
| ACME（≥1.14） | `tls.certificate_provider = {type:"acme", domain[], email, data_directory}` | 文档：inline `tls.acme` 1.14 起废弃、1.16 移除 |
| ACME（≤1.13） | `tls.acme = {domain[], email, data_directory}` | 1.12/1.13 无 `certificate_provider` |
| 目录 | `data_directory = /var/lib/sbox/acme`，由 `sbox` 用户可写 | `ProtectSystem=strict` 下必须 |

ACME 域名规则：必须是解析到本机的真实域名（不能是 IP 或伪装站点）；校验走 HTTP-01（80）或 TLS-ALPN（443）。

## 3. 客户端 profile（订阅）

文档：`configuration/dns/`、`configuration/dns/server/udp|https/`、`configuration/dns/rule_action/`、
`configuration/route/`、`configuration/inbound/tun/`、`configuration/outbound/{urltest,selector,direct}/`、
`configuration/experimental/{cache-file,clash-api}/`

| 字段 | 值 | 文档/版本 |
| --- | --- | --- |
| `dns.servers[].type` | `udp`（223.5.5.5:53）、`https`（dns.google，`domain_resolver: dns-cn`，`detour: proxy`） | 1.12 起新式 DNS server；域名服务器必须配 `domain_resolver` |
| `dns.rules[].action` | `route` + `server` | 1.12+ DNS 规则动作化 |
| `dns.final` / `strategy` / `cache_capacity` / `reverse_mapping` | `dns-proxy` / `prefer_ipv4` / 8192 / true | 全部为文档字段（`cache_capacity` 1.11+） |
| `route.default_domain_resolver` | `"dns-cn"`（字符串标签） | 文档：string 或 object |
| `route.auto_detect_interface` | true | ✓ |
| `route.rules` | `hijack-dns`（限 tun-in）、`ip_is_private → direct` | ✓ |
| `inbounds[0]` | `tun`：`address` / `auto_route` / `strict_route` / `mtu 1420` | `address` 1.10+；`stack` 1.15 起废弃 → **未输出** |
| `inbounds[1]` | `mixed` 127.0.0.1:2080（桌面复用） | ✓ |
| `outbounds` | 各节点 + `urltest(auto)` + `selector(proxy, default auto)` + `direct` | ✓（`idle_timeout` 为文档字段） |
| `experimental.cache_file` | `{enabled: true}` | `cache_file` 1.8+ |
| `experimental.clash_api` | `external_controller`、`default_mode: "Rule"` | ✓ |

### 版本门槛导致的取舍
为保证订阅在 **1.12+ 的所有客户端**都能导入，profile 刻意不输出下列 1.14-only 字段：

| 字段 | 引入版本 | 处理 |
| --- | --- | --- |
| `dns.timeout` | 1.14 | 不输出（1.12/1.13 报 `unknown field "timeout"`） |
| `experimental.cache_file.store_dns` | 1.14 | 不输出（1.12/1.13 报 `unknown field "store_dns"`） |
| `inbounds[].stack` | 1.15 废弃 | 不输出 |

## 4. 实测矩阵

### 4.1 配置解析（`sing-box check`）

| 版本 | 服务端配置（含 Reality/Hy2/AnyTLS/TUIC/ACME 节点） | 客户端 profile |
| --- | --- | --- |
| v1.12.25 | ✓（ACME 自动降级为 `tls.acme`） | ✓ |
| v1.13.21 | ✓（同上） | ✓ |
| v1.14.4 | ✓（ACME 用 `certificate_provider`） | ✓ |
| v1.15.0-alpha.13 | ✓ | ✓ |
| mihomo v1.19.34 | — | ✓（`mihomo -t`） |

### 4.2 运行时（1.14.4 回环）

服务端 5 类节点（VLESS Reality、Hysteria2、Hysteria2+obfs、AnyTLS、TUIC）→ 客户端用订阅 profile
（去掉 tun）实际发起连接：

```
通过 127.0.0.1:28080（mixed）→ https://api.ipify.org       200
通过 127.0.0.1:28080（mixed）→ https://www.cloudflare.com  200
服务端日志无 error/fatal；urltest 依次探测 vless/tuic/anytls 节点
```

### 4.3 真机（Debian 13 VPS，1.14.4）

此前已验证：四协议 + Hysteria2 obfs 分别通过 mihomo 客户端访问外网 200；订阅 JSON 直接
`sing-box run` 可用；1.14.4 ↔ 1.15.0-alpha.13 往返切换后服务与协议仍正常；IP 证书 SAN 正确；
Reality 对未授权握手返回伪装站点证书。

## 5. 结论

- 四协议的 inbound/outbound 字段与官方文档逐项一致；差异仅为「未使用 1.14 新增的可选字段」。
- 客户端 profile 使用 1.14 的模板结构，同时通过裁剪 1.14-only 字段保证 1.12+ 兼容。
- 分享链接参数（`security=reality`、`flow=xtls-rprx-vision`、`pbk/sid`、`alpn`、`allow_insecure`）
  与 sing-box / mihomo / v2rayN 的解析习惯一致。

### 剩余风险（非代码问题）
1. ACME 依赖：真实域名 A 记录指向本机 + 80 或 443 可达；伪装 SNI 不能用于签发。
2. 移动端 tun 需要系统权限（iOS/Android 由 App 处理），桌面 CLI 需 root/管理员。
3. 1.16 将移除 inline `tls.acme`；届时 ≤1.15 的降级分支需再评估（≥1.14 已使用新写法）。

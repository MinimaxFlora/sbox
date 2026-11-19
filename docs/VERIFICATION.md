# 验证记录（v0.3.6）

所有结论均来自真实执行，不是推断。

## 0. v0.3.6 真机回归（2026-11-19，189.105.68.13 / Debian 13 / amd64）

真实 Let's Encrypt 环境（域名 `bn.tatalvpai.vip`），6 节点 × 2 客户端全矩阵：

| 项目 | 结果 |
| --- | --- |
| ACME 真签发 | 证书落盘 `/var/lib/sbox/acme/certificates/acme-v02.api.letsencrypt.org-directory/bn.tatalvpai.vip/`，到期 2027-02-16 |
| 证书状态反馈 | `sbox node cert` 显示 `ACME✓ 已签发（到期 …）`；`sbox doctor` 逐节点输出 ACME 状态 |
| ACME 节点地址 | 链接/订阅 `server` = `bn.tatalvpai.vip`（不再是 IP），`insecure=0` |
| 自签节点 | `--sni bn.tatalvpai.vip` 的自签节点链接为域名 + `insecure=1`，两客户端均可连 |
| 分享链接 | anytls / hysteria2 / tuic / vless 四类格式正确，hy2 obfs 参数完整 |
| mihomo 1.19.34 | anytls、hy2443、tuic8443、vless443、hy2obfs(salamander)、anyself 出口全部 189.105.68.13 |
| sing-box 1.14.4 客户端 | 同一订阅 JSON（tun→mixed）6 节点全部出口 189.105.68.13，Google 204 |
| 客户端日志 | mihomo / sing-box 客户端 error+fatal 计数均为 0 |
| 版本切换 | 切到 1.15.0-alpha.13 后 6 节点 × 1.15 客户端全部通过、服务端 0 错误；已切回 1.14.4 |
| 订阅公网访问 | 外部主机请求 `/singbox` `/mihomo` `/v2ray` `/auto` 均 200，错误令牌 404，`Content-Disposition: sbox.json` |
| 443 端口共存 | TCP（VLESS-Reality）与 UDP（Hysteria2）同时监听并各自可用 |
| 最终状态 | 4 节点、两服务 active、`sbox doctor` 全通过 |

测试用的 `hy2obfs` / `anyself` 节点与临时脚本已清理，VPS 只保留 4 个正式节点。

## 1. 自动化测试（CI + 本地）

面板：GitHub Actions（`ubuntu-26.04` 托管 runner），每次 push/tag 触发 lint → test → package。

```
lint     bash -n + python 编译 + shellcheck(0.10.0)   ✅
test     tests/test.sh 64 项通过 / 0 失败              ✅
package  make package + sha256 校验                     ✅
release  tag 自动建 Release 并上传 tar.gz/sha256        ✅（v0.1.0 ~ v0.3.6）
```

覆盖内容：四种协议节点创建（含 Hysteria2 obfs）、`sing-box check` 服务端与客户端（1.12/1.13/1.14/1.15 四代）、
`mihomo -t` 配置校验、分享链接格式、ACME 语义（域名 + `insecure=0`、缺域名拒绝、证书落盘识别）、
自签默认证书名不是第三方域名、订阅接口（singbox/mihomo/v2ray/auto）、错误令牌 404、
Basic 认证 401/200、IP 证书 SAN。

## 2. 真实服务器（Debian 13，amd64，systemd）

| 项目 | 结果 |
| --- | --- |
| 安装（`install.sh --local`） | 通过，创建 `sbox` 用户与两个 systemd 单元 |
| 服务身份 | `User=sbox`、`AmbientCapabilities=CAP_NET_BIND_SERVICE`、`ProtectSystem=strict` |
| 端口共存 | VLESS 443/tcp 与 Hysteria2 443/udp 同时监听 |
| 自签证书 | `SAN: IP:189.105.68.13`（IP 证书场景） |
| Reality 握手 | 未授权客户端看到 `CN=www.microsoft.com`（正确借用目标站点） |
| 订阅接口（公网访问） | `/health`、`/singbox`、`/mihomo`、`/v2ray`、`/auto` 均 200；错误令牌 404 |
| 订阅内容 | Base64 解码出 4 条链接，主机/端口/参数正确 |
| 端到端代理 | mihomo 客户端分别走 AnyTLS / Hysteria2 / TUIC / VLESS-Reality / Hysteria2-obfs，`https://api.ipify.org` 与 Google 均 200 |
| sing-box 客户端配置 | 订阅返回的 JSON（去掉 tun）实际启动，走代理访问成功 |
| 版本切换 | 1.14.4 (stable) ↔ 1.15.0-alpha.13 (testing) 往返切换，配置校验通过、服务正常、四种协议仍可用 |
| 节点运维 | 非交互改端口（8443→8445→8443）、删除节点、重新生成证书均生效并自动重启 |
| 订阅认证 | `sbox sub auth` 后 401/200 正确，关闭后恢复 200，令牌重置即时生效 |
| BBR | 由 cubic 切到 bbr（容器环境亦可） |
| 卸载/重装 | 卸载清空单元/配置/用户，重装后重新建 4 节点，服务与订阅正常 |
| 自更新 | `sbox update --local` 在服务器上热更新（0.3.5 → 0.3.6 实测） |
| 自检 | `sbox doctor` 全项通过 |
| 日志 | 最近 200 行无 error/fatal |

## 3. 已知限制

- 服务端仅支持 systemd 发行版（OpenRC 未适配）。
- 订阅服务需要 python3（安装时自动装）。
- ACME 需要真实域名且 80/443 可达；纯 IP 部署只能用自签证书（脚本自动写 IP SAN）。
- GitHub 仓库为公开仓库，可直接 `curl -fsSL https://raw.githubusercontent.com/MinimaxFlora/sbox/main/install.sh | bash` 一键安装，无需手动传包。

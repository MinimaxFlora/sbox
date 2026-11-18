# 验证记录（v0.2.2）

所有结论均来自真实执行，不是推断。

## 1. 自动化测试（CI + 本地）

面板：GitHub Actions（`ubuntu-26.04` 托管 runner），每次 push/tag 触发 lint → test → package。

```
lint     bash -n + python 编译 + shellcheck(0.10.0)   ✅
test     tests/test.sh 51 项通过 / 0 失败              ✅
package  make package + sha256 校验                     ✅
release  tag 自动建 Release 并上传 tar.gz/sha256        ✅（v0.1.0 ~ v0.2.2）
```

覆盖内容：四种协议节点创建（含 Hysteria2 obfs）、`sing-box check` 服务端与客户端、
`mihomo -t` 配置校验、分享链接格式、订阅接口（singbox/mihomo/v2ray/auto）、错误令牌 404、
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
| 自更新 | `sbox update --local` 在服务器上热更新到 v0.2.2 |
| 自检 | `sbox doctor` 全项通过 |
| 日志 | 最近 200 行无 error/fatal |

## 3. 已知限制

- 服务端仅支持 systemd 发行版（OpenRC 未适配）。
- 订阅服务需要 python3（安装时自动装）。
- GitHub 仓库为公开仓库，可直接 `curl -fsSL https://raw.githubusercontent.com/MinimaxFlora/sbox/main/install.sh | bash` 一键安装，无需手动传包。

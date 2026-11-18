# sbox — Sing-Box 一键脚本

[![CI](https://github.com/MinimaxFlora/sbox/actions/workflows/ci.yml/badge.svg)](https://github.com/MinimaxFlora/sbox/actions)
![version](https://img.shields.io/badge/version-0.3.2-blue)
![license](https://img.shields.io/badge/license-MIT-green)

面向 VPS 的 **Sing-Box 一键管理与订阅脚本**，只保留最实用的四种协议，配置全部使用
**sing-box 1.12+ 新格式**，同时输出 **sing-box / mihomo(Clash) / v2rayN** 三种订阅。

> GitHub 公网镜像：<https://github.com/MinimaxFlora/sbox>（由 `scripts/sync-github.sh` 从本仓库生成，
> 内含 GitHub Actions 工作流，可直接 `curl -fsSL https://raw.githubusercontent.com/MinimaxFlora/sbox/main/install.sh | bash`）

## 特性

| 能力 | 说明 |
| --- | --- |
| 协议 | `VLESS Reality Vision`、`Hysteria2`、`AnyTLS`、`TUIC v5`（可任意组合、多实例共存） |
| 分享 | 通用 URI 分享链接 + 终端/图片二维码，格式与 v2rayN、小火箭、sing-box 一致 |
| 订阅 | sing-box JSON（新格式）、mihomo YAML、Base64 链接列表、UA 自动识别 |
| 版本 | 稳定版 / 测试版（alpha、beta）/ 指定版本热切换，自动校验配置后再重启 |
| 证书 | 自签 ECDSA、ACME 自动签发、手动证书三种模式 |
| 安全 | 非 root 运行 + systemd 沙箱、配置校验失败自动回滚、订阅令牌 + 可选 Basic 认证 |
| 运维 | 交互菜单、命令行长参数、`sbox doctor` 自检、BBR 开关、防火墙自动放行 |

## 一键安装

```bash
# 稳定版 sing-box
curl -fsSL https://raw.githubusercontent.com/MinimaxFlora/sbox/main/install.sh | bash

# 测试版 sing-box（alpha）
curl -fsSL https://raw.githubusercontent.com/MinimaxFlora/sbox/main/install.sh | bash -s -- --channel testing
```

支持系统：Debian / Ubuntu / CentOS / Rocky / AlmaLinux / Fedora / Arch（需 systemd）。
支持架构：`amd64`、`arm64`、`armv7`、`armv6`、`386`、`riscv64`、`loong64`。

安装完成后 `sbox` 即是管理入口：

```bash
sbox                # 交互菜单（推荐）
sbox help           # 命令说明
```

## 快速开始

```bash
# 添加节点（不带参数会逐项询问；带参数可全自动）
sbox node add vless                                  # VLESS Reality Vision，默认 443/tcp
sbox node add vless --name hk --port 443 --sni www.microsoft.com
sbox node add hysteria2 --name hy2 --port 443 --sni your.domain.com --cert selfsigned
sbox node add anytls    --name at  --port 8444 --sni your.domain.com
sbox node add tuic      --name tu  --port 8443 --sni your.domain.com

sbox node list                 # 节点表格
sbox node link hk              # 分享链接 + 二维码
sbox sub                       # 三种订阅地址 + 二维码
sbox status                    # 系统 / 服务 / 节点 / 订阅总览
sbox node edit tuic --port 8445    # 非交互修改（也可交互菜单）
sbox node cert hy2                 # 重新生成自签证书（支持 IP SAN）
sbox sub auth user pass            # 订阅 Basic 认证（不带参数则关闭）
```

## 交互菜单

```
 1) 状态总览            6) 节点链接 & 二维码
 2) 添加节点            7) 订阅链接管理
 3) 节点列表 / 详情     8) sing-box 版本管理
 4) 修改节点            9) 服务控制 & 日志
 5) 删除节点            b) BBR 加速   u) 更新脚本   0) 退出
```

## 订阅

订阅服务默认监听 `0.0.0.0:2087`，令牌为 32 位随机串（见 `/etc/sbox/sbox.conf` 的 `SUB_TOKEN`）。

| 用途 | 地址 |
| --- | --- |
| sing-box（1.12+ 新格式） | `http://<地址>:2087/<token>/singbox` |
| mihomo / Clash | `http://<地址>:2087/<token>/mihomo` |
| v2rayN / 小火箭 | `http://<地址>:2087/<token>/v2ray` |
| 自动识别（按 UA） | `http://<地址>:2087/<token>/auto` |

- `singbox` 返回完整客户端配置：`tun` + `mixed` 双入站、`selector` 出站、`default_domain_resolver`，可直接导入 SFI/SFA/SFM 或 `sing-box run -c`。
- `mihomo` 返回完整 Clash 配置（`mixed-port`、代理组、分流规则），也可作为 proxy-provider 的 `url`。
- `v2ray` 返回 Base64 编码的节点链接列表，兼容 v2rayN、Shadowrocket、Quantumult X 等。
- 可选 HTTP Basic 认证：在 `/etc/sbox/sbox.conf` 中设置 `SUB_USER` / `SUB_PASS` 后执行 `sbox apply`。

## sing-box 版本管理

```bash
sbox version                       # 当前版本 / 通道 / 已安装版本
sbox version switch stable         # 最新稳定版（当前 1.14.x）
sbox version switch testing        # 最新测试版（alpha，当前 1.15.0-alpha.x）
sbox version switch 1.14.4         # 指定版本
```

切换流程：解析 release → 下载对应架构包 → 安装到 `/usr/local/lib/sbox/versions/<tag>/`
→ **用新二进制校验现有配置** → 替换 `/usr/local/bin/sing-box` 软链 → 重启服务。
校验不通过会取消切换，原有版本继续运行。

下载镜像：GitHub 直连失败时可设置 `SBOX_GH_MIRROR=https://your-proxy/`（会以
`<mirror>/https://github.com/...` 形式拼接）。

## 目录结构

```
/usr/local/lib/sbox/          脚本代码与多版本二进制
  ├── sbox.sh                 入口
  ├── src/lib/*.sh            模块（common/sys/version/tls/node/render/link/sub/service/setup/menu/cli）
  ├── src/subserver/          订阅服务（Python 标准库，无第三方依赖）
  └── versions/<tag>/sing-box 各版本二进制
/usr/local/bin/sbox           → /usr/local/lib/sbox/sbox.sh
/etc/sbox/
  ├── sbox.conf               全局配置（地址、订阅端口/令牌、版本通道、默认 SNI）
  ├── config.json             服务端 sing-box 配置（自动生成，勿手改）
  ├── nodes/<name>.meta       节点元数据（key=value）
  ├── certs/<node>/           自签证书
  └── sub/                    订阅文件快照（排查用）
/var/lib/sbox/                systemd StateDirectory
```

## 安全设计

- **非 root 运行**：`sing-box` 与订阅服务以 `sbox` 系统用户运行，仅保留 `CAP_NET_BIND_SERVICE`
  以便绑定 443；单元启用 `NoNewPrivileges`、`ProtectSystem=strict`、`ProtectHome`、
  `PrivateTmp`、`MemoryDenyWriteExecute`、`RestrictAddressFamilies` 等加固项。
- **最小权限文件**：配置、节点元数据、证书为 `root:sbox 640`；目录 `750`；`sbox.conf` 同样受限。
- **配置安全**：所有生成值经过校验与 JSON 转义；每次应用配置先 `sing-box check`，
  失败自动回滚并保留上一版本；不 `eval` 任何用户输入。
- **订阅防护**：随机令牌、可选 Basic 认证、`Cache-Control: no-store`、错误令牌返回 404。
- **网络边界**：自动放行节点端口与订阅端口（ufw / firewalld / nftables），删除节点时同步关闭。

## 常用命令

```bash
sbox status                  # 总览
sbox start | stop | restart  # 服务控制
sbox apply                   # 重新渲染配置 + 刷新单元 + 重启
sbox log [行数]              # 服务日志
sbox sub port 2087           # 修改订阅端口
sbox sub token               # 重置订阅令牌
sbox doctor                  # 环境自检
sbox bbr                     # 开启 BBR
sbox update                  # 更新脚本本体
sbox uninstall               # 卸载
```

## 开发与测试

```bash
make lint      # bash -n + shellcheck
make test      # 单元测试 + 配置校验 + 订阅接口测试（需 sing-box / mihomo 二进制）
bash tests/fetch-binaries.sh   # 拉取测试用 sing-box / mihomo
```

测试覆盖：语法、shellcheck、四种节点的创建、服务端配置 `sing-box check`、
客户端 JSON `sing-box check`、mihomo 配置 `mihomo -t`、分享链接格式、订阅接口与令牌校验。

## 发版流程

1. 修改 `VERSION`（语义化版本）与 `CHANGELOG.md`
2. 提交并打 tag：`git tag -a v0.1.1 -m 'v0.1.1' && git push origin v0.1.1`
3. GitHub Actions 自动执行 lint / test，并打包 `sbox-<tag>.tar.gz` + `sha256` 上传到 Release

发布使用仓库内置的 `GITHUB_TOKEN`，无需额外 Secret。

## 常见问题

**端口被占用？** `sbox node add` 会自动挑选可用端口；也可 `--port` 指定。
VLESS Reality（TCP）与 Hysteria2（UDP）可以同时使用 443。

**自签证书客户端报错？** 分享链接已带 `insecure=1`，sing-box / mihomo 客户端会自动跳过校验。
推荐使用 ACME 模式或手动证书以获得受信任链路。

**Reality 的 SNI 选什么？** 默认 `www.microsoft.com`，可改为当地可访问、支持 TLS1.3 的站点
（如 `www.apple.com`、`www.cloudflare.com`）；修改后需重新导出链接。

**没有域名怎么办？** Hysteria2 / AnyTLS / TUIC 直接用服务器 IP 作为 SNI 即可：
`sbox node add hysteria2 --sni 1.2.3.4`，自签证书会自动写入 **IP SAN**，
客户端链接带 `insecure=1`（mihomo 为 `skip-cert-verify: true`）。

**Clash 订阅导入失败？** 新版 mihomo 内核才支持 AnyTLS/TUIC；旧内核请升级，或改用 `v2ray` 格式。

## 免责声明

本项目仅用于学习与自有网络环境的技术研究，请在符合当地法律法规的前提下使用。

## 许可

MIT

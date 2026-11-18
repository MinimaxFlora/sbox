# Changelog

本项目遵循 [语义化版本](https://semver.org/lang/zh-CN/)。
版本号格式：`MAJOR.MINOR.PATCH`，预发布版追加 `-alpha.N` / `-beta.N`。

## [0.3.3] - 2026-11-18

### 修复（ACME）

- **不再把伪装 SNI 当作 ACME 域名**：选中 ACME 后会单独询问真实域名，未提供直接拒绝创建
  （此前会静默沿用 `www.bing.com`，申请必然失败）
- ACME 节点的 `server_name`/分享链接 SNI 自动等于 ACME 域名，链接不再带 `insecure=1`
- ACME 不再输出 `certificate_path`/`key_path`（旧模板因此报 `cert: unbound variable` 并生成无效 JSON）
- sing-box ≥ 1.14 使用 `tls.certificate_provider`（1.13 及以下回退到已废弃的 `tls.acme`）
- ACME 数据目录固定为 `/var/lib/sbox/acme` 并由服务用户可写（`ProtectSystem=strict` 下可写）
- 证书准备失败时**不再落盘半个节点**（此前会写出没有域名的 ACME 节点，导致后续渲染失败）

### 新增

- `sbox node edit <名称> --acme-domain D [--acme-email E]` 切换 ACME
- `sbox node edit <名称> --selfsigned` 回退自签证书
- 交互菜单「修改节点」新增 `7) 证书方式（自签 / ACME / 手动）`

## [0.3.2] - 2026-11-18

### 修复

- 订阅中的 sing-box 客户端配置改为 **1.14 官方模板结构**（参考 sing-box-yg）：
  字符串 `default_domain_resolver`、`dns-cn`/`dns-proxy` DNS 服务器（`domain_resolver` + `detour`）、
  `action: route` 的 DNS 规则、`auto_detect_interface`、tun `mtu 1420`（去掉 `stack`）、
  `cache_file.store_dns`、`urltest` + `selector` 代理组，避免旧字段导致客户端导入报错
- 订阅响应增加 `Content-Disposition: attachment; filename="sbox.json|yaml|txt"`

## [0.3.1] - 2026-11-18

### 修复

- 测试运行产生的 `cache.db` 被误提交，现删除并加入 `.gitignore`

## [0.3.0] - 2026-11-18

### 新增

- GitHub 公网镜像：`scripts/sync-github.sh` 从本仓库生成 GitHub 版目录树
  （去掉 `.gitea/`、写入 `.github/workflows/ci.yml`、替换仓库地址与文档措辞）并推送
- GitHub Actions 工作流：`ubuntu-26.04` 托管 runner，`actions/checkout@v7`、
  `actions/upload-artifact@v7`，tag 触发 `gh release create` 发布

### 改进

- 安装与自更新同时兼容 Gitea（`/archive/<ref>.tar.gz`）与 GitHub
  （`/archive/refs/heads/<ref>.tar.gz`）两种代码包地址

## [0.2.3] - 2026-11-18

### 文档

- 新增 `docs/VERIFICATION.md`：CI 与真实服务器（Debian 13 VPS）验证记录、已知限制

## [0.2.2] - 2026-11-18

### 改进

- 交互式添加节点时提示「端口」与「SNI」（回车即用推荐值），非交互模式仍全自动

## [0.2.1] - 2026-11-18

### 修复

- `--yes` 未生效（卸载等默认答案为「否」的确认被取消）
- `die` 触发 ERR trap 时重复打印行号信息（现在只输出一次原因）

## [0.2.0] - 2026-11-18

### 新增

- 自签证书支持 **IP SAN**（无域名场景可直接用服务器 IP 作为 SNI）
- `sbox node cert [名称]`：查看证书到期时间 / SAN，或重新生成自签证书
- `sbox node edit <名称> --port/--sni/--uuid/--password/--addr/--regen-key`：非交互式修改节点
- `sbox sub auth [用户 密码]`：订阅 HTTP Basic 认证；令牌与认证配置即时生效，无需重启
- `sbox update --local <目录>`：从本地代码目录热更新（适合无法访问内网仓库的 VPS）
- `sbox bbr` 支持容器化环境（逐项 sysctl + 内核模块加载 + 结果校验）

### 修复

- Hysteria2 `--obfs-password` 等带连字符参数无法解析（obfs 缺失密码时配置校验失败）
- 订阅认证/令牌修改后仍沿用旧配置（服务端改为每请求重读）
- 修改端口后订阅服务未重启（端口变更后自动重启）
- CI 中相对路径二进制导致节点创建失败、checksum 校验路径错误

## [0.1.0] - 2026-11-18

### 新增

- 一键安装 / 卸载，自动创建 `sbox` 系统用户与 systemd 单元
- 四种入站协议：VLESS Reality Vision、Hysteria2、AnyTLS（1.12+）、TUIC v5
- 节点增删改查、分享链接（通用 URI 格式）、终端二维码
- 订阅服务：`/<token>/singbox`（1.12+ 新格式 JSON）、`/<token>/mihomo`（Clash YAML）、
  `/<token>/v2ray`（Base64 链接）、`/<token>/auto`（按 UA 自动识别）
- sing-box 版本管理：稳定版 / 测试版（alpha、beta）/ 指定版本热切换，切换前后自动校验配置
- 证书管理：自签（ECDSA P-256）、ACME 自动签发、手动证书
- 安全加固：服务以非 root 用户运行 + systemd 沙箱、文件权限 640 组只读、
  订阅令牌、可选 HTTP Basic 认证、配置校验失败自动回滚
- 自动化测试与 Gitea Actions CI（语法 / shellcheck / 配置校验 / 端到端协议验证）

### 说明

- 服务端配置使用 sing-box 1.12+ 新格式，不含已废弃的 `block`/`dns` 出站与旧版 DNS 字段
- 订阅中的 sing-box 客户端配置包含 `tun` 与 `mixed` 入站、`selector` 出站与 `default_domain_resolver`

# 3x-ui Shadowsocks 中转一键部署 v1.2

这个脚本只解决一个目标：在 Debian/Ubuntu VPS 上部署单节点、单密码的 `shadowsocks-libev` 服务，供另一台 3x-ui 主机作为 Shadowsocks 出站使用。

默认加密方式是当前 3x-ui 与发行版 `shadowsocks-libev` 共同支持的 `aes-256-gcm`，也可明确选择 `chacha20-ietf-poly1305`。本脚本不部署 SS2022。

## 最快部署

在任意目标 VPS 上运行一条命令：

```bash
curl -fsSL https://raw.githubusercontent.com/OryLite/3xui-ss-relay/main/setup-shadowsocks-libev.sh | sudo bash
```

如果脚本已经在 VPS 本机：

```bash
sudo bash setup-shadowsocks-libev.sh
```

指定端口和加密方式：

```bash
curl -fsSL https://raw.githubusercontent.com/OryLite/3xui-ss-relay/main/setup-shadowsocks-libev.sh \
  | sudo bash -s -- --port 23456 --method aes-256-gcm
```

首次部署会自动完成以下工作：

- 安装发行版 `shadowsocks-libev` 及所需工具；
- 自动识别中转 VPS 的公网 IPv4；
- 未指定时生成随机端口和强随机密码；
- 启动并设为开机自启，验证同一服务进程同时监听 IPv4 TCP 与 UDP；
- 若系统已经安装 UFW，则管理对应的 TCP、UDP 用户规则；
- 在终端显示地址、端口、密码、加密方式、SS 链接和完整 3x-ui Outbound JSON。

## 更稳妥的下载方式

`curl | bash` 最方便，但不能在执行前人工检查内容。更稳妥的做法是先下载、校验，再运行：

```bash
curl -fL https://raw.githubusercontent.com/OryLite/3xui-ss-relay/main/setup-shadowsocks-libev.sh \
  -o /tmp/setup-shadowsocks-libev.sh
printf '%s  %s\n' \
  'b8310fd02e2bfdecc2c1ea8eb6288839f5032272542c8b4f3f7e6ccf60aa2481' \
  '/tmp/setup-shadowsocks-libev.sh' | sha256sum -c -
sudo bash /tmp/setup-shadowsocks-libev.sh
```

发布新版本后，必须以同一版本的 `SHA256SUMS` 为准，不能继续使用上面的旧哈希。

## 3x-ui 如何填写

脚本成功后会直接打印实际配置和 JSON。使用表单时填写：

- 协议：`shadowsocks`
- 标签：任意，例如 `ss-relay`
- 发送通过：留空
- 地址：中转 VPS 的公网 IPv4，不是 3x-ui 主机的 IP
- 端口：脚本输出的端口
- 密码：脚本输出的密码
- 加密：必须与脚本一致，默认 `aes-256-gcm`
- UDP over TCP：关闭
- 传输：`RAW`
- 安全：`无`
- Mux：关闭

3x-ui 主机的公网 IP 不需要填写到 Shadowsocks 出站中。只有在服务端使用 `--allow-from` 限制防火墙来源时，才需要把 3x-ui 主机的公网 IPv4 作为来源参数。

## 常用命令

普通重跑会保留现有端口、密码和加密方式；配置没有变化时不会重启服务或新增备份：

```bash
sudo bash setup-shadowsocks-libev.sh
```

更换密码：

```bash
sudo bash setup-shadowsocks-libev.sh --rotate-password
```

切换为 ChaCha20：

```bash
sudo bash setup-shadowsocks-libev.sh --method chacha20-ietf-poly1305
```

从文件第一行读取密码，避免把明文密码写进 shell 历史和进程参数：

```bash
sudo bash setup-shadowsocks-libev.sh --password-file /root/ss-password.txt
```

仅预览，不安装、不写文件、不管理服务：

```bash
bash setup-shadowsocks-libev.sh --server 1.2.3.4 --dry-run
```

## 防火墙

默认行为：如果 VPS 已经安装 UFW，脚本为实际端口添加 IPv4 TCP 和 UDP 规则。脚本不会自动安装或启用 UFW，也不会修改云厂商安全组。

只允许 3x-ui 主机公网 IP 访问中转端口：

```bash
sudo bash setup-shadowsocks-libev.sh --allow-from 203.0.113.10
```

重新改为允许全部 IPv4 来源：

```bash
sudo bash setup-shadowsocks-libev.sh --open-firewall
```

不让脚本管理 UFW，并删除本脚本以前记录的规则：

```bash
sudo bash setup-shadowsocks-libev.sh --no-firewall
```

注意：

- `--allow-from` 要求 UFW 已启用，且默认入站策略是 `DROP` 或 `REJECT`；
- 它只管理本脚本的 UFW 用户规则，不能证明自定义 nftables/iptables、`before.rules` 或云防火墙没有其他放行路径；
- 本机监听成功不代表公网一定可达，云安全组也要放行同一端口的 IPv4 TCP 和 UDP。

## 已安装过 shadowsocks-libev 怎么办

如果只是先运行过：

```bash
sudo apt install shadowsocks-libev
```

且仍是发行版自动生成的默认配置，脚本会识别并安全接管，不需要先卸载。

如果 `/etc/shadowsocks-libev/config.json` 已经被人工或其他程序修改，脚本默认拒绝覆盖。确认要接管时才使用：

```bash
sudo bash setup-shadowsocks-libev.sh --adopt-existing
```

从旧 v1.1 模板实例迁移，例如旧实例名为 `relay`：

```bash
sudo bash setup-shadowsocks-libev.sh --migrate-from relay
```

旧配置使用 `aes-128-gcm` 时，普通重跑不会静默切换并断开旧客户端；必须明确确认迁移：

```bash
sudo bash setup-shadowsocks-libev.sh --method aes-256-gcm
```

## HTTPS、域名与协议边界

这个中转不需要域名，也不需要 HTTPS 证书。3x-ui 通过 Shadowsocks 协议连接中转 VPS 的公网 IPv4、端口、密码和加密方式；面板自身的 HTTPS 证书与这条出站无关。

发行版 `shadowsocks-libev` 暂不支持 `2022-blake3-*`，所以不能在 3x-ui 保持默认 SS2022 加密后连接本脚本部署的服务。请在面板里主动选择 `aes-256-gcm` 或 `chacha20-ietf-poly1305`。

本脚本只管理一个服务和一套凭据：

- 服务：`shadowsocks-libev.service`
- 配置：`/etc/shadowsocks-libev/config.json`
- 状态：`/var/lib/ss-libev-relay/state.json`
- 事务标记：`/var/lib/ss-libev-relay/transaction.json`
- 备份：`/var/backups/ss-libev-relay/`，最多保留最近 5 份

它不是多用户面板，也不提供配额、到期时间或逐用户流量统计。

## 支持范围

- Debian 或 Ubuntu
- systemd 247 或更高版本
- IPv4 公网地址
- `aes-256-gcm`（默认）
- `chacha20-ietf-poly1305`（可选）
- 单端口、单密码、TCP 与 UDP

不支持：CentOS/AlmaLinux、OpenRC、IPv6 出站地址、SS2022、多用户和多实例。

## 最终验收状态

版本 `v1.2.0`、SHA-256 `b8310fd02e2bfdecc2c1ea8eb6288839f5032272542c8b4f3f7e6ccf60aa2481` 已完成以下隔离环境验证：

- Debian 12：全新安装、APT 预装接管、人工配置接管、v1.1 实例迁移、幂等重跑、密码轮换、端口冲突回滚和重启自启；
- Ubuntu 22.04：`aes-256-gcm`/`chacha20-ietf-poly1305` 部署、幂等重跑和重启自启；
- Ubuntu 24.04：`aes-256-gcm` 部署、幂等重跑和重启自启；
- UFW：全部 IPv4、限定来源、禁用脚本管理三种状态及其切换、重复运行和失败保护；
- 静态与参数：`bash -n`、完整 ShellCheck、33 项正向/负向 CLI 用例。

详细结果见 `TEST_REPORT.md`。容器环境不能代替目标 VPS 的云安全组和真实公网连通性验证。

## 排查命令

```bash
systemctl status shadowsocks-libev.service --no-pager
journalctl -u shadowsocks-libev.service -n 100 --no-pager
ss -lntup
ufw status verbose
ufw show added
```

脚本只会在部署成功后显示密码。密码仍可能保留在终端滚屏或会话录制中，请按自己的运维环境处理。

## 发布与部署状态

公开仓库：<https://github.com/OryLite/3xui-ss-relay>

仓库发布不会自动同步或修改任何 VPS。只有在目标 VPS 上主动执行安装命令后，脚本才会安装和配置服务。

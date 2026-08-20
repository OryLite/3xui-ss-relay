# v1.2 最终验收报告

## 结论

- 脚本：`setup-shadowsocks-libev.sh`
- 版本：`1.2.0`
- 行数：2670
- SHA-256：`b8310fd02e2bfdecc2c1ea8eb6288839f5032272542c8b4f3f7e6ccf60aa2481`
- 结果：全部最终回归通过，未发现 P0/P1 阻断问题
- GitHub 目标仓库：`OryLite/3xui-ss-relay`
- VPS 状态：发布仓库时没有同步或修改任何真实 VPS

## 静态与参数验证

- `bash -n`：通过
- ShellCheck v0.10.0 完整默认级：通过，退出码 0、无输出
- CLI/dry-run：33/33 通过

参数矩阵覆盖：

- 默认 `aes-256-gcm`
- `chacha20-ietf-poly1305`
- IPv4/CIDR 规范化
- `--open-firewall`、`--allow-from`、`--no-firewall`
- 非法/私网/保留 IPv4、IPv6、FQDN
- 端口上下界、前导零和非法字符
- 拒绝 `aes-128-gcm` 新建和 `2022-blake3-*`
- 拒绝旧接口 `--password`、`--name`
- 密码文件、参数缺失、未知参数和互斥组合

## Debian 12

以下场景均通过：

- 从未安装软件包的空环境开始部署
- 先执行 `apt install shadowsocks-libev`，再由脚本识别发行版默认配置并接管
- 默认服务 active、enabled，Docker 重启后自动恢复
- 配置权限为 `root:ss-libev-relay-config 0640`
- 状态文件权限为 `root:root 0600`
- `DynamicUser` 服务进程不是 root，只通过专用补充组读取配置
- 同一 MainPID 拥有 IPv4 TCP 与 UDP 监听
- 没有意外 IPv6 监听
- 普通重跑保持配置哈希、状态哈希、PID 和备份数量不变
- `--rotate-password` 只轮换密码并重启服务，状态文件不保存密码
- 目标端口被 TCP/UDP 占用时部署失败，原配置、密码、服务和监听全部恢复
- 默认无 UFW 时服务仍可用，状态记录 `ufw-missing` 并输出明确警告

## UFW

在 Debian 12 特权容器内使用真实 UFW 命令验证：

1. `--open-firewall`
2. `--allow-from 10.20.30.40/16`，规范化为 `10.20.0.0/16`
3. `--no-firewall`

每个启用状态都精确维护一条 TCP 和一条 UDP 规则；切换后旧注释规则被完整删除，重复运行不新增规则。UFW inactive 时，限定来源模式按预期拒绝且不修改服务或状态。

容器的 sysctl 与裸机不同，因此此项证明规则生成、查询、切换和回滚逻辑，不代表真实公网数据包已经穿过云安全组。

## Ubuntu

### Ubuntu 22.04

- systemd 249
- shadowsocks-libev 3.3.5+ds-7build1
- 全新部署、两种允许的加密方式、幂等重跑和容器重启：通过

### Ubuntu 24.04

- systemd 255
- shadowsocks-libev 3.3.5+ds-10build3
- 全新 `aes-256-gcm` 部署、幂等重跑和容器重启：通过

## 接管与迁移

人工修改的默认配置在没有 `--adopt-existing` 时被安全拒绝，文件不变；明确接管后保留端口、密码和允许的加密方式，记录 `source_kind=adopted` 并收敛权限。

真实 v1.1 模板实例迁移验证：

- 旧服务 `shadowsocks-libev-server@relay.service` 初始为 active、持久 enabled
- 不加 `--migrate-from relay` 时安全拒绝
- 明确迁移后默认服务接管原端口、密码和加密方式
- 默认服务 active、enabled，并拥有 TCP/UDP 监听
- 旧服务 inactive、disabled
- 旧配置保留为 `root:root 0600`
- 精确匹配的旧 drop-in 被删除
- 状态记录 `source_kind=migration`、`migrated_from=relay`
- 普通重跑无变化，容器重启后默认服务恢复、旧服务仍不启动

## 已知边界

- 按用户要求，成功或无变化重跑都会在终端显示密码、SS URI 和 JSON；这些内容可能进入终端滚屏、cloud-init 或 CI 日志。
- 若配置历史上曾以过宽权限暴露，脚本只能修复当前权限，无法证明旧密码没有泄露；可运行 `--rotate-password`。
- v1.1 没有可靠的 UFW 所有权状态，迁移时不会自动删除可能属于其他管理员的旧规则，会提示人工检查。
- 自定义 nftables/iptables、UFW `before.rules`、云防火墙和云安全组不在脚本的完整控制范围内。
- 只支持单节点、单端口、单密码和公网 IPv4，不提供多用户、配额或逐用户统计。

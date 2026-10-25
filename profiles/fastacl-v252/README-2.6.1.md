# FastACL V2.6.1

本版本在 V2.6.0 的 Factory 无线身份修复基础上，重点处理长期运行稳定性、DNS 防泄漏和 WAN 自动恢复。

## 稳定性修复

- FastACL guard 改为 10 秒采样，连续两次异常后才恢复，恢复动作限频 120 秒。
- 检测 SOCKS5 `15443` 接收队列、代理连接数、DNS/dae 文件描述符、nft 私有表和 DNS 防泄漏规则。
- DNS/代理入口异常时优先热恢复故障组件，避免全量冷启动和 `daens` 命名空间残留。
- dae 空闲 TCP 隧道从 5 分钟缩短为 2 分钟，半关闭连接从 10 秒缩短为 5 秒。
- 文件描述符上限提升到 16384，同时保留资源阈值监控。
- 健康指标每 5 分钟写入 `/root/fastacl252-health.log`，超过 64 KiB 自动轮转。

## DNS 防泄漏

- 所有附加 WiFi 的 IPv4 TCP/UDP 53 请求保留客户端来源并重定向到 FastACL DNS。
- 硬编码公共 DNS 同样无法绕过；无线 IPv6 DNS 采用 fail-closed 丢弃。
- guard 同时检查 DNS 重定向链和 IPv6 DNS 阻断规则，规则丢失时会自动修复。

## WAN 看门狗

- 独立 procd 服务监测 WAN carrier、IPv4 地址、默认网关和公网连通性。
- 连续 3 次失败后执行 DHCP renew，连续 9 次失败后重建 WAN，并设有冷却时间。
- WAN 看门狗提供 LuCI 开关和命令行开关：
  - `系统 -> WAN Watchdog`
  - `/usr/bin/wan-watchdog enable|disable|status`
- 状态保存在 `/tmp/wan-watchdog.status`，动作日志保存在 `/root/wan-watchdog.log`。

## NPS 启动顺序

- 保留开机后等待 40 秒再初始化 NPS 的原有设计。
- NPS 初始化会等待 IPv4 默认路由和物理 WAN MAC 同时就绪，并在 WAN `ifup/ifupdate` 后重新启动客户端。
- WAN 事件已成功启动 NPS 时，通过 `/tmp` 就绪标记跳过 40 秒定时器的重复启动。
- 使用进程锁避免开机初始化和 hotplug 同时修改 NPS 配置。

## 无线默认值

- 2.4 GHz 默认使用信道 1、HE20，降低拥挤信道和 40 MHz 兼容性问题。
- 5 GHz 默认使用信道 36、HE80，避免 V2.6.0 默认 HE160 跨越 DFS 频段。
- 双频默认国家码统一为 CN。
- 已有设备通过一次性迁移脚本调整旧默认值，不覆盖用户自行选择的其它信道。
- 批量创建无线时从界面填写的起始编号开始生成 SSID，并在写入任何配置前检查 32 字节上限和现有 SSID 重名。

## 验证

- 10 个代理槽全部通过连通性测试。
- 50 个并发代理请求后 `15443` 队列保持为 0，dae 文件描述符未持续增长。
- DNS 唯一域名审计期间 WAN TCP/UDP 53 抓包为 0。
- DNS/SOCKS 入口故障注入后约 20 秒自动恢复，dae PID 保持不变。
- WAN 连续 30 次探测 0% 丢包。
- 模拟客户端完整 DNS、nft、dae 链路访问百度为 HTTP 200，Google 204。
- RAX3000M NAND / MT7981 实机 14 个无线接口 BSSID 全部唯一，UCI 和 MTWiFi profile 均不存在额外 per-VAP MAC 覆盖。
- 同一实机 WPA2 四次握手完成后成功取得 DHCP 地址，未发现认证失败或关联失败日志。

## 边界

- 外部代理节点和运营商链路故障不能由本地看门狗消除，但本地组件会记录并自动恢复。
- 客户端 DNS 收口到 FastACL 后，dnsmasq 的 `.lan` 主机名不再用于无线客户端解析。

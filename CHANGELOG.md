# JuLiang FastACL 版本演进记录

> 本文件记录 FastACL 从 V9 稳定化到当前正式版的主要 Bug 修复、功能演进、兼容性变化和关键提交。
>
> 维护原则：数据面优先稳定、默认 fail-closed、防 DNS/IPv6 泄漏；Operator 只开放必要能力；PassWall/PassWall2 作为节点/兼容层，不接管 FastACL 正常数据面。

---

## 2.4.0 Stable

### 新增功能
- Operator「无线」页面每个 SSID 增加 **隐藏无线 / 显示无线**。
- 页面顶部增加 **一键隐藏全部 / 一键显示全部**。
- 每个 SSID 显示 **广播中 / 已隐藏** 状态。
- 使用 OpenWrt 原生 `wireless.<iface>.hidden=1/0` 控制 SSID 广播。
- 隐藏 SSID **不会关闭无线接口**，不改变 DHCP、网段、FastACL 分配和透明代理。
- 提供已安装系统运行时升级脚本：
  - `scripts/upgrade-fastacl-2.4.0-wireless-visibility.sh`

### 版本更新
- FastACL 配置版本由 `V9-FIX3` 正式更新为 `2.4.0`。

### 关键提交
- `1fac0dbfd68c74adb395df7bb36f62358e53741a` — 无线隐藏/显示后端 API。
- `ef04d4193956d02a773dc50f48c338c00d5f0b80` — 单 SSID + 全部隐藏/显示前端。
- `d24bad070d966029e9b1364373e8e68e61601a39` — 配置版本更新。
- `2fa09a2695677d9532c0ae1185bf8628b0a92897` — 首启迁移版本更新。
- `938c8d71bd21335f237341b730979dc48fa2a65d` — 已安装系统 2.4.0 在线更新脚本。

---

## 2.3.9 Stable

### 主要修复
- 部分 MTK `mt_wifi` 驱动的 station `rx_bytes/tx_bytes` 长期为 0，导致客户端实时流量无法正确显示。
- 改用独立 nftables 客户端计数器作为 fallback，补齐每台终端的实时上传/下载统计。
- 精简无线页面客户可见说明，移除多余权限/技术提示。

### 新增功能
- 每个无线客户端实时显示：
  - IP
  - MAC
  - 信号强度
  - 无线链路速率
  - 实时上传
  - 实时下载
- 固定并冻结为 2.3.9 known-good 正式核心。

### 正式版整合
- MT7981 5WiFi / 10WiFi 正式工作流。
- Operator 默认普通账号支持。
- SSH Dropbear 端口调整到 `20022`。
- PassWall / PassWall2 增加：
  - `socks5://user:pass@host:port`
  - `socks://user:pass@host:port`
  - `http://user:pass@host:port`
  - `host:port:user:pass`
  - 多行批量导入
- 修复 Xray SOCKS 出站错误继承 `mark=255`。
- 固件构建加入 nftables userspace。
- 增加 standalone 完整安装器。

### PassWall2 兼容修复
- 修复访问控制模板 `acl_ip_refresh.htm` / `acl_exit_ip_status.htm` 的 Lua 模板结构校验。
- FastACL 开启时隐藏旧 ACL 出口面板，避免和 FastACL 控制逻辑混淆。
- FastACL 关闭时仍保留 PassWall2 ACL 页面可用性。

### sing-box 1.12+ 运行时兼容
- 修复：
  `missing route.default_domain_resolver or domain_resolver`
- 迁移到 `route.default_domain_resolver`。
- 提供已安装系统运行时修复：
  - `scripts/repair-fastacl239-singbox112-runtime.sh`
- 提供 PassWall2 专用 SK5/HTTP 修复：
  - `scripts/repair-passwall2-sk5-http.sh`

### 关键提交
- `7be6d43842663293ecf88e96b4115db39d2e94cb` — nft 客户端流量 fallback。
- `588bbb2888ed39c2a75a666695d3fa132eda0904` — 实时设备速度计数。
- `ff6fda0889c28d84e652bb220410690b6589188c` — 客户端流量与 UI polish。
- `17b2fa2fc14638f3b205bcd6e1576562e521e992` — 2.3.9 Stable 最终锁定基线。
- `69fc0c77a3669ea249f05117149daf557baade05` — standalone 安装器。
- `2049b19f87b7832d1d40edd7798001024ae91bc2` — 正式固件 nftables userspace。
- `bf711402f7fbedacdcd806e5f5d513fa68b3ed7f` — PassWall2 SK5/HTTP 运行时修复。
- `38f2c524ffe29ece383061731068d5a5508a64ea` — sing-box 1.12+ 运行时修复。

---

## 2.3.8

### 主要目标
从“能控制代理”升级到“能看见设备和网络状态”。

### 新增功能
- Operator 首页增加真实 WAN IP。
- WAN / LAN 接口状态。
- 端口链路状态。
- 总流量统计。
- 实时上传/下载图表。
- 每个 SSID 的在线终端列表。
- 终端 IP / MAC / 信号 / 无线速率。
- 初步的每终端实时上传/下载。

### 关键提交
- `8457f3a6ef51382710f25192850141be8d760f11` — WAN/interface telemetry + 客户端列表。
- `99e6faa058335746cbc52c35d6c3ed837820f304` — 每 SSID 终端、IP/MAC/信号/实时速率。
- `fb68d06e08fdd5590c144ceec0695c98fb6ba69a` — WAN IP、流量图、总量和端口状态。
- `0e0f7eb188ea104dceb23c514cd58f7b8bbfc059` — 2.3.8 设备端整合修复。

---

## 2.3.7

### 主要修复
- Operator 受限账号通过 LuCI 间接读取 UCI 时，FastACL 已导入节点偶尔不可见。
- 旧完整无线菜单和安全无线编辑器同时存在，容易误操作。
- 自定义 Operator 首页可能影响 root 用户 QuickStart 首页。

### 新增 / 调整
- FastACL 控制器改为 scoped direct UCI。
- 安全无线编辑器改为 direct scoped UCI 写入。
- 删除 Operator 可见的完整无线菜单入口。
- Operator 使用独立首页。
- root 保留正常 QuickStart 首页。

### Fix1
- 修复自定义首页 Lua long-string 语法错误。

### Fix2
- 恢复 root QuickStart 首页，仅 Operator 使用自定义首页。

### Fix3
- 修复 Lua `gsub()` 多返回值进入 `tonumber()` 导致首页运行时异常。

### 关键提交
- `262bdfb29eeddfc79a504ba23939a4f242b1c4cb` — FastACL scoped direct UCI。
- `892b4174ec679beb50cc0d1bad16ae1448245b01` — 无线 scoped direct UCI。
- `c5deaebcf4045735c35992beec947e1fb53e9066` — Fix1。
- `5634f375968d3476e49bed7ff8ea98391cc23907` — Fix2。
- `71fc5a8f35d724bc0a78be5e16d1e16a592b1572` — Fix3。

---

## 2.3.6

### 主要目标
让普通 Operator 用户可以安全修改无线，而不是开放完整 OpenWrt 无线后台。

### 新增功能
- 安全无线编辑器。
- 只允许修改：
  - SSID
  - 密码
  - 信道
- Operator 首页无线入口改为安全编辑器。
- 不开放 DHCP、防火墙、接口、完整 UCI 权限。

### 关键提交
- `f9e2e6f72f5e04600567c55ec77f97a794c8fc70` — 受限无线控制器。
- `6229791902f03569c2915153a7206c0d152e4d57` — SSID/密码/信道编辑器。
- `46d961a45d69654ab3697ed28caafbeff509dfc0` — Operator 只暴露安全无线入口。

---

## 2.3.5

### 主要修复
- 通过修改 QuickStart/iStore 页面来限制普通用户菜单的方案过于脆弱。
- 部分 LuCI session / getFeatures 权限不足导致 Operator 页面加载不稳定。

### 新增功能
- 独立极简 Operator 首页。
- 不再依赖覆盖 iStore 页面来实现普通用户界面。
- 补齐 LuCI `getFeatures` 和 session 权限。
- 原生隐藏 iStore 菜单。

### 关键提交
- `37e78226d3784f18b1571c02ba47798381fe13f2` — 独立极简首页。
- `26816c51f8326eb53499f3bff2637742e435f3ad` — 独立 Operator 首页。
- `6732068f46c3a8e02dff84d638d916d4bc41feb1` — LuCI session/getFeatures 权限。
- `a382ec6c6f3423fcbb51efe1d98cc0ec2a4cb6b1` — 原生隐藏 iStore 菜单。

---

## 2.3.4

### 主要目标
把 FastACL 从 root 管理工具推进到可交付给普通用户使用的产品。

### 新增功能
- LuCI-only Operator 普通账号。
- Operator 不创建 Linux 用户，不具备 SSH shell。
- 独立 rpcd ACL。
- 限制菜单到必要功能。
- Operator 可以使用 FastACL 节点导入。
- 内部化节点导入接口。

### Fix1
- 修复 session expiry。
- 修复空白用户名。
- 修复 iStore 菜单仍可见。
- 修复首次安装 UCI 配置不存在。
- 避免依赖 OpenWrt 上不一定存在的完整 `install` 工具行为。

### 关键提交
- `e7c3f121f3c640d4fd2ff278a4589500e559d440` — Operator ACL + 内部节点导入。
- `340b7cd41d57768bc8163f5ff0fe0bf14ed9fa8d` — rpcd ACL 组。
- `03f46911f62d83303ae5dd11836fcb04ca2ec630` — Operator 账号管理器。
- `c5fd9ab5d8ea0fac62689b65660f6873a12c0aea` — 设备端安装器。
- `d104585e412aace85ff73d5d1b03c78b9a002e9e` — Fix1 session/iStore/login。
- `e947ca314b5ea1ae7f30e1bf8e2c0b1ea7aac022` — 首次创建 UCI package。

---

## 2.3.3

### 主要修复
主 LAN 被 FastACL 接管后，仍存在 IPv6 / DNS 绕过透明代理、暴露真实出口的风险。

### 修复内容
- 主 LAN IPv6 防绕过。
- DNS 防泄漏。
- fail-closed forwarding 改为动态按 zone 匹配。
- 修复主 LAN 视频/网络异常场景。

### 关键提交
- `5017640265823846b9b145e9b6791e3ec282a3f1` — 主 LAN IPv6/DNS 防泄漏 + 动态 fail-closed。
- `3fe164659fd5a302d050905e91548c1f12398e15` — IPv6 DNS 阻断和 zone fail-closed。
- `17770de0003e0e7ea4c4b3fafa3e4687b7c49696` — 2.3.3 最终验证基线。

---

## 2.3.2

### 新增功能
- 自动发现主 LAN。
- 主 Wi-Fi 和有线 LAN 都可以成为 FastACL 分配目标。
- 主 LAN 不占用/打乱 A1、A2… 的 AP slot。
- 新发现子网分配节点后自动刷新 dataplane。
- 默认启用 main LAN discovery。

### 关键提交
- `08f60e59680afa8ca0627aa53857068df219a2d5` — 主 LAN Wi-Fi + 有线发现。
- `99d70dcb6a0eb7936793d0d69073d7d49d6f64bf` — 默认启用 main LAN discovery。
- `89c7eaab6228b8bf7e5cc137c68479fcc910570f` — 新分配子网自动刷新 dataplane。
- `d2de56d7262341a1684dd54977f3914a1971eeb4` — 2.3.2 设备端整合修复。

---

## 2.3.1

### 主要目标
在不动稳定数据面的前提下改善 FastACL 控制台体验。

### 新增 / 改进
- Argon/FastACL 页面加宽。
- 节点导入入口更明显。
- 节点列表更清晰。
- 探测结果持续显示。
- 统一 SK5 简写导入体验。

### 关键提交
- `beb69a104414cb8364c0ec13b010e6f8af952bcc` — UI polish。
- `efbf5a574c1ccf772c1d6d89cb577e3cf82a2afe` — 2.3.1 UI-only hotfix。

---

## 2.3.0

### 主要目标
经历 V9 Fix4.x 快速迭代后，重新冻结一套 known-good 数据面。

### 修复 / 决策
- 恢复稳定版 `juliang-fastacl`。
- 恢复稳定版 Guardian。
- 保留 fail-closed 设计。
- 将后续 UI/Operator 改进建立在稳定数据面之上。

### 关键提交
- `3cfca3ff2632ac33374423b0b114b469ee4c6b96` — known-good FastACL runtime。
- `168ca64ed048b4aabb622073f512cc75469cb83c` — known-good Guardian。

---

# V9 稳定化阶段（2.3.0 之前）

## V9 Fix1
- 首次加入持久 FastACL 配置。
- Guardian 持续强制 fail-closed。
- 自动清理旧 V8 保留下来的 A→WAN forwarding。
- 编译阶段确保 FastACL UI/runtime 真正进入最终 rootfs。

关键提交：
- `309242dcba0a818584452c7752be7c26c2c41965`
- `5e6e51a184f28a397750b6f759b6ffc3df06ca94`
- `9072e4d4454a325e76558d1b849ee2ade483d624`

## V9 Fix2
- 强制使用当前 FastACL runtime。
- 迁移 preserved overlay。
- 修复 5WiFi → 10WiFi 升级后保留旧配置的问题。

关键提交：
- `f9307bae5e97a7ce6d97cea2cd71a7c79985e1b1`

## V9 Fix3
- 修复 MOVE 节点顺序问题。
- 增加 real-exit health watchdog。
- Guardian 并行出口探测。
- 限制自动恢复频率，减少抖动。
- 动态 fail-closed firewall。
- 健康检测参数持久化。
- 动态 ACL UI。
- 编译环境补 host Lua 5.1，解决离线 LuCI patch 构建失败。

关键提交：
- `fea1d17e515da676e33359519b0d60a4e9573456`
- `3cd7c661fb5cf207fdb1f5a102a7f71f21df36a8`
- `2568832daae2a2331deb0fa567f2bb0f10b833d8`
- `44b2e84c99bf0a69c8be48474534228c9b1b31c6`

## V9 Fix4
- 增加独立 FastACL 控制台。
- 节点分配、链式代理管理、切换、回滚统一进入 FastACL 页面。
- 提高链路切换稳定性。

关键提交：
- `e370efdab3a6ed19cdac6a4cd51d8227567898f2`
- `a3dcf6b004e287ef730e169a7868b9806289c693`

## V9 Fix4.1
- Guardian 使用非阻塞维护锁。
- 修复 operation-lock PID。
- 清理 stale preproxy 探测状态。
- 提升健康节点切换速度。

关键提交：
- `79aa19775705ac9e84419669f50eb226de1b983a`
- `440641ecafe246f07cf2b9c0f4e7ce3f75005226`
- `1c48291944d3ecdc0be9423a2fb1979051f85473`

## V9 Fix4.2
- 修复切换 SK5 后旧 listener 仍存活。
- 防止旧出口 IP/cache 被新节点继续复用。

关键提交：
- `6774690efefe35ca1eb828e47bc7a20e0f3d1fb4`
- `22fa0dc0d9d8eaa7045b31992c57981ff7aa54b5`

---

# 独立兼容分支说明

## Legacy iptables / sing-box 1.9
这套兼容仅针对早期旧 OpenWrt 设备：
- iptables legacy
- sing-box 1.9.x
- 无 nft/fw4

**不得合入现代 FastACL nft/fw4 固件。**

相关提交：
- `8fd8c8ee0d4ce0a4f03d6ffafbedabf004acb698`
- `6bc72561a94b3e99beb049f7342b8313a3e749ea`
- `247aad7b3dd952b568fa579360b315bc120b1ab2`

---

# 当前正式版能力总览

当前 **FastACL 2.4.0 Stable** 包含：

- FastACL TProxy 多 SSID/多网段控制。
- 节点导入、分配、MOVE、切换。
- 前置中继 / 链式代理。
- Guardian。
- real-exit health watchdog。
- fail-closed kill-switch。
- 主 LAN / 主 Wi-Fi / 有线 LAN 支持。
- DNS / IPv6 防泄漏。
- Operator 受限普通用户。
- 独立 Operator 首页。
- 安全无线编辑器。
- WAN / LAN / 端口状态。
- 总流量和实时流量。
- 每 SSID 客户端。
- 每客户端 IP / MAC / 信号 / 无线速率。
- 每客户端实时上传 / 下载。
- PassWall / PassWall2 SK5 / SOCKS5 / HTTP 导入兼容。
- Xray SOCKS mark 修复。
- PassWall2 访问控制页面兼容。
- sing-box 1.12+ `default_domain_resolver` 兼容。
- 单 SSID 隐藏 / 显示。
- 一键隐藏全部 / 一键显示全部。

---

# 后续版本记录模板

以后每个版本按下面格式追加：

## X.Y.Z

### 修复 Bug
- 

### 新增功能
- 

### 兼容性
- 

### 已安装系统在线升级
- 脚本：
- 是否需要重启：
- 是否需要重新刷固件：

### 关键提交
- `SHA` — 说明

### 验证结果
- [ ] FastACL router running
- [ ] Guardian running
- [ ] sing-box check passed
- [ ] juliang_killswitch present
- [ ] DNS/IPv6 leak protection
- [ ] Operator UI
- [ ] Wireless UI
- [ ] Client traffic
- [ ] PassWall2 compatibility

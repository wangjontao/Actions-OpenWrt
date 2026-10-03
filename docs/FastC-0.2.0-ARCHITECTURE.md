# FastC 0.2.0 重构架构

目标：像 FastACL 一样，所有日常调试/切换均采用热切换，不因节点操作重启 mihomo，不干扰 FastACL/PassWall/PassWall2/其它核心，并将 CPU/交互延迟降到路由器可接受范围。

## 1. 核心原则

1. **mihomo 常驻**：除内核升级、配置结构性错误、致命崩溃外，不允许 `restart`。
2. **控制面与数据面分离**：UI/RPC 只发增量命令；数据面只维护 TProxy/TUN、DNS、策略组与链对象。
3. **热切换优先**：A 组出口切换使用 selector API；诊断使用独立 probe selector；不触发主配置重载。
4. **原子事务**：无线重新分配、前置链变更均采用 prepare -> validate -> commit；失败回滚 last-good。
5. **互斥占用**：一个无线组默认只能有一个主出口；新节点绑定 A1 时必须先释放旧主出口，再原子写入新绑定。
6. **链式代理独立化**：链对象与节点对象分离，前置链改变不修改无线组主绑定；链失败立即回滚上一条可用链。
7. **诊断不碰主链路**：延时/IP 检测仅使用单一共享 probe listener，不改主 selector、不重载主配置。
8. **低频 Guardian**：默认 15s，仅批量读取状态；只有发现偏移/故障才执行纠正。
9. **低负载默认**：默认 `TProxy + DNS Hijack`；TUN 为可选兼容模式，不默认启用。
10. **Fail-closed**：任意切换失败不允许回落到 WAN 直连。

## 2. UI 重构

默认页面只保留：

- 节点列表：节点名、协议、地址、所属无线、前置链、检测结果、操作。
- 顶部：FastACL/FastC 模式、mihomo 状态、数据面状态、导入节点。
- “当前无线出口”改为折叠面板，默认关闭；只有需要调试时展开。
- 大节点池分页/搜索；前置链选择按需加载。
- 所有操作必须即时 Toast + 行内状态：`应用中 -> 已成功` / `失败并已回滚`。

## 3. 无线绑定模型

使用 `/etc/fastc/bindings.json` 作为唯一真相源（source of truth）：

```json
{
  "A1": {"ssid":"SSID-1","subnet":"172.16.1.0/24","node":"n0004"},
  "A2": {"ssid":"SSID-2","subnet":"172.16.2.0/24","node":"n0002"}
}
```

节点表中的 `group` 仅为显示/索引，不再作为冲突判断依据。

### 重新分配规则

把 n0008 分配到 A1：

1. 读取 A1 当前 node（例如 n0004）。
2. prepare：生成候选 bindings，A1=n0008。
3. validate：n0008 存在、协议可用、链无环、目标无线存在。
4. commit：一次原子 rename 覆盖 bindings.json。
5. API 热切换 FASTC-A1 -> n0008。
6. 成功：更新 UI；n0004 自动释放为“未分配”。
7. 失败：恢复旧 bindings + FASTC-A1 -> n0004。

不允许出现“旧 A1 不释放、新 A1 也写进去”的双占用状态。

## 4. 链式代理模型

链式关系从节点记录中分离到 `/etc/fastc/chains.json`：

```json
{
  "n0004": {"via":"n0001"},
  "n0005": {"via":"n0001"}
}
```

规则：

- `n0004 via n0001` 表示 n0004 为最终落地，n0001 为前置。
- 最终出口 IP 应为 n0004 的出口。
- 自链/循环链禁止。
- 变更链前先验证新链。
- 链热更新失败，回滚上一次 last-good 链。
- 不允许因链修改重启 mihomo 主进程。

## 5. 诊断模型

只保留一个共享节点探测 selector + listener：

- `FASTC-NODE-PROBE`
- `127.0.0.1:18200`

单次“检测”默认只建立 **1 条代理连接**：

- 请求轻量 HTTP IP endpoint
- 同一次 curl 获取 `time_starttransfer`
- 返回 `{ip, latency_ms}`

不同时调用 `/delay` + IP 探测；失败时最多一次备用 endpoint。

无线组出口检测也按需触发，不在页面刷新时自动检测。

## 6. 数据面模式

### 默认：TProxy

- TCP/UDP 透明代理
- 源网段 -> 独立 FASTC-Ax selector
- 53 端口 DNS Hijack 到 mihomo 内部 DNS
- 远程 DNS 只通过代理解析
- nftables KillSwitch 防直连泄漏

### 可选：TUN

仅作为兼容模式：

- 适合必须全接管/特殊应用兼容场景
- 默认关闭以降低 CPU 和内核开销
- 与 TProxy 二选一，不同时启用

## 7. 热切换接口约定

控制面后续统一提供：

- `bind_wireless(node, group)`：原子释放旧占用并热切 selector
- `set_group_node(group, node)`：只 API PUT，不 reload
- `set_chain(node, via)`：链对象热更新 + validate + rollback
- `probe_node(node)`：共享探测器，不影响主流量
- `probe_group(group)`：只在用户点击时执行
- `switch_dataplane(tproxy|tun)`：安全切换数据面
- `switch_engine(fastacl|fastc)`：FastACL/FastC fail-closed 交接

## 8. 禁止事项

FastC 0.2.0 中以下行为视为架构 Bug：

- 选择节点后直接 `/etc/init.d/fastc restart`
- 修改前置链后直接重启 mihomo
- 页面刷新时逐组/逐节点发大量 curl
- 检测一个节点并发创建多条完整链路
- 一个无线组存在两个“主出口”绑定
- 失败后保留半更新状态
- TUN 与 TProxy 同时接管同一无线
- FastC 故障时自动直连 WAN

## 9. 迁移策略

0.1.8 保留为历史开发版，不继续堆功能。
0.2.0 新 profile 独立开发，先实现：

1. bindings/chains 新状态模型
2. selector 热切换事务
3. 单 probe 检测器
4. 折叠 UI
5. TProxy 稳定版
6. 可选 TUN
7. FastACL/FastC 热交接

只有核心流程全部通过后才提供 0.2.0 安装器。

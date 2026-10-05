# FastACL 2.4.4 iptables 适配版

适用条件：LuCI Lua、PassWall2、IPv4/IPv6 iptables-legacy、iptables-restore、ip6tables-restore、sing-box 1.12.x。拒绝活动 fw4/nftables。

基于 2.4.3 iptables 后端，整合 2.4.4 无线批量操作后刷新节点列表修复、PassWall/PassWall2 ACL 模板修复，以及兼容 processData 第四参数 add_from/group 的 SK5/SOCKS5/HTTP 批量导入修复。

2026-10-05 已在 RAX3000M、23.05.5、内核 6.6.56 实机安装验证：FastACL router / iptables / killswitch 运行，原有 6 个网络、5 个节点记录核对保留，三种协议批量导入成功，测试节点已删除，两个 ACL 模板由 LuCI 原生解析器校验通过。未验证所有机型。

核心采用官方 sing-box 1.12.25 linux-arm64，经 UPX 5.0.2 压缩为 18267688 字节；原始来源为 SagerNet/sing-box v1.12.25。由于旧设备闪存有限，这个版本需单独准备核心；安装器不会自动更新核心。

运行安装器前可使用 --check 做兼容检查。安装器备份覆盖文件和关键配置，并提供 rollback.sh。替换 sing-box 时另备份核心，回退 FastACL 不会自动回退核心。

源码与内置 payload 一并保存在 install-fastacl244-full-iptables.sh。现有正式 nftables 版本及 2.4.3 冻结分支不改动。

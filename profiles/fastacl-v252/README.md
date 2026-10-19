# FastACL 2.5.5/Fast

This independent `codex/fastacl255` branch combines the 2.4.4 application-switching model with the official dae v2.1.1/eBPF dataplane for JuLiangTK S20L / ImmortalWrt 24.10. The package is `2.5.5-r1`.

Node, preproxy and DNS changes use `fastacl252 hot-apply`. The normal hot path keeps both daemon PIDs, reloads dae in process, swaps DNS policy snapshots through a root-only Unix control socket, and atomically updates only FastACL's private nft table when its rules change. It never reloads network, WiFi or the system firewall. A fixed-IP binding change alone can reload dnsmasq. Established dae connections may retain their previous exit; new connections use the updated policy.

Creating/removing managed WiFi changes topology and uses the cold path. SSID visibility changes reload wireless only. The health-driven guard repairs missing private firewall rules without restarting healthy daemons; an actual dae reload failure may fall back to a dae-only restart. A rejected DNS reload retains the working DNS policy and listeners. Protection rules are installed before native-core validation, including during startup recovery.

The main WiFi retains per-device MAC + fixed-IP routing, with unbound devices direct by default. Optional WiFi networks are created on demand, up to 14 additional 5GHz and 8 additional 2.4GHz networks, with separate bridges, DHCP, firewall zones and exit/DNS policies. Used subnets are excluded from the 172.16.x.0/24 allocation pool.

Manual import accepts SOCKS5/SK5/HTTP/HTTPS/VLESS/VMess/Trojan/SS/Hysteria2/TUIC and host:port:user:pass lines. Subscription formats include HTTPS lists, Base64, Clash YAML and sing-box JSON. Device- and WiFi-bound subscription nodes are retained when removed upstream. Proxy DNS requires DoH and uses the assigned proxy chain without a direct fallback.

This branch removes the legacy HOTFIX-6 first-boot substitutions. Native UCI writes, octal permissions, empty JSON object maps and protocol registration are tested directly rather than relying on permissive API mocks.

Both Lite CI gates run shell/Lua syntax checks, import/subscription regressions, native Go tests with the race detector, persistent DNS TCP-session and daemon PID tests, runtime lifecycle/rollback tests, native dae configuration validation and browser UI tests. The shell lifecycle tests stub external commands and do not prove eBPF behavior. Real S20L cold boot, WiFi radio operation, simultaneous device/WiFi switching, failure isolation and measured switching latency remain hardware acceptance checks. CI success alone is not a hardware pass.

The firmware excludes iStore, QuickStart, PassWall, PassWall2, HomeProxy and OpenClash. NPS uses nps.jontao.top:8024 with an uppercase physical-WAN-MAC VKey. Restricted LuCI operator access is included; SSH uses port 20022.

Official dae source: https://github.com/daeuniverse/dae/tree/v2.1.1 (AGPL-3.0).

See [FastACL 2.5.5 release notes](README-2.5.5.md) for the current on-device baseline and validation limits.

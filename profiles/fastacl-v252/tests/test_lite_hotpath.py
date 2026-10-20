#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
controller = (ROOT / "root/usr/lib/lua/luci/controller/fastacl252.lua").read_text(encoding='utf-8')
runtime = (ROOT / "root/usr/bin/fastacl252").read_text(encoding='utf-8')
init = (ROOT / "root/etc/init.d/fastacl252").read_text(encoding='utf-8')
pkg = (ROOT / "package-Makefile").read_text(encoding='utf-8')
defaults = (ROOT / "root/etc/uci-defaults/99-juliangtk-fastacl252").read_text(encoding='utf-8')


def between(text: str, start: str, end: str) -> str:
    a = text.index(start)
    b = text.index(end, a + len(start))
    return text[a:b]


assert "version='2.5.6'" in controller
assert "PKG_VERSION:=2.5.6" in pkg
assert "fastacl252.main.version=2.5.6" in defaults

# Managed WiFi node/preproxy/DNS updates are pure application-layer switches.
wifi_update = between(controller, "if req.action=='update' then", "if req.action=='hide_all'")
assert "apply_now('hot-apply')" in wifi_update
for forbidden in (
    "/etc/init.d/network reload",
    "wifi reload",
    "/etc/init.d/firewall restart",
    "/etc/init.d/dnsmasq restart",
):
    assert forbidden not in wifi_update, f"hot WiFi update must not run {forbidden}"

# Main-LAN device/node/DNS save is also a hot path.  DHCP reload is allowed
# only for a real fixed-address change; no network/wifi/firewall reload exists.
main_save = between(controller, "function save()", "function import_nodes()")
assert "apply_now('hot-apply')" in main_save
assert "dhcp_changed" in main_save
for forbidden in (
    "/etc/init.d/network reload",
    "wifi reload",
    "/etc/init.d/firewall restart",
    "/etc/init.d/dnsmasq restart",
):
    assert forbidden not in main_save, f"main hot save must not run {forbidden}"

# Topology changes reload netifd once, then hot-apply the dae configuration.
wifi_all = between(controller, "function wifi_action()", "function subscription()")
assert "apply_now('hot-apply')" in wifi_all
assert "apply_now('cold-apply')" not in wifi_all
assert "/etc/init.d/network reload" in wifi_all
assert "/etc/init.d/firewall restart" in wifi_all

# Runtime hot apply uses dae's application reload and private nft table only.
hot = between(runtime, "hot_apply(){", "cold_apply(){")
assert "generate_next" in hot
assert "firewall_apply" in hot
assert "reload_dns_next" in hot
assert "reload_dae_next" in hot
for forbidden in ("/etc/init.d/network", "wifi reload", "/etc/init.d/firewall"):
    assert forbidden not in hot, f"runtime hot apply must not call {forbidden}"
assert 'dae reload "$pid"' in runtime
assert "app-restart" in runtime

# Guardian is health-driven, not a 15-second unconditional apply loop.
guard = between(runtime, "guard)", "cleanup)")
assert "if ! dae_ready || ! dns_ready" in guard
assert "/usr/bin/fastacl252 ensure" in guard
assert "/usr/bin/fastacl252 apply" not in guard

# fw4 changes must not be a procd trigger that races node switches.
assert "procd_add_reload_trigger fastacl252" in init
assert "procd_add_reload_trigger fastacl252 firewall" not in init

print("FastACL 2.5.6 hot-path architecture: OK")

# DNS hot updates must acknowledge a live in-process reload, never stop listeners.
dns_hot = between(runtime, "reload_dns_next(){", "# dae's own reload")
healthy_reload = dns_hot[dns_hot.index('cp "$R/dns.json"'):]
assert 'dns_reload_control >' in healthy_reload
assert 'fastacl252-dns -reload' in runtime
assert 'fastacl252-control.lua dns' in runtime
assert 'dns_stop' not in healthy_reload
assert 'start_dns_next' not in healthy_reload
assert not (ROOT / 'root/etc/uci-defaults/95-fastacl252-hotfix6-fast-switch').exists()
assert '+libuci-lua' in pkg


#!/bin/sh
set -eu

PIN="39a28b48f4a342c39e54efbe6f7e42020a092506"
BASE="https://raw.githubusercontent.com/wangjontao/Actions-OpenWrt/$PIN/profiles/fastacl-v9/root"
TMP="/tmp/jfa-v9-fix1-$$"
mkdir -p "$TMP" /tmp/juliang-fastacl /etc/juliang-fastacl
trap 'rm -rf "$TMP"' EXIT INT TERM

echo "=================================================="
echo " JuLiang FastACL V9 Fix1 - on-device repair"
echo "=================================================="

fetch_if_missing() {
    src="$1"; dst="$2"; mode="$3"
    if [ ! -s "$dst" ]; then
        echo "[INFO] missing $dst ; downloading embedded V9 runtime..."
        mkdir -p "$(dirname "$dst")"
        curl -4 -fL --connect-timeout 8 --max-time 60 --retry 2 -o "$dst" "$BASE/$src"
    fi
    chmod "$mode" "$dst"
}

fetch_if_missing "usr/bin/juliang-fastacl" "/usr/bin/juliang-fastacl" 0755
fetch_if_missing "usr/bin/juliang-fastacl-guard" "/usr/bin/juliang-fastacl-guard" 0755
fetch_if_missing "usr/bin/juliang-fastacl-luci-install" "/usr/bin/juliang-fastacl-luci-install" 0755
fetch_if_missing "usr/libexec/juliang-fastacl-router.lua" "/usr/libexec/juliang-fastacl-router.lua" 0644
fetch_if_missing "usr/libexec/juliang-fastacl-relay.lua" "/usr/libexec/juliang-fastacl-relay.lua" 0644
fetch_if_missing "usr/libexec/juliang-fastacl-discover.lua" "/usr/libexec/juliang-fastacl-discover.lua" 0644
fetch_if_missing "usr/lib/lua/luci/controller/juliang_fastacl.lua" "/usr/lib/lua/luci/controller/juliang_fastacl.lua" 0644
fetch_if_missing "etc/init.d/juliang-fastacl" "/etc/init.d/juliang-fastacl" 0755
fetch_if_missing "etc/hotplug.d/iface/99-juliang-fastacl" "/etc/hotplug.d/iface/99-juliang-fastacl" 0755

touch /etc/config/juliang_fastacl
uci -q get juliang_fastacl.main >/dev/null || uci set juliang_fastacl.main='main'
uci set juliang_fastacl.main.enabled='1'
uci set juliang_fastacl.main.tproxy_port='12345'
uci set juliang_fastacl.main.mark='0x66'
uci set juliang_fastacl.main.route_table='100'
uci set juliang_fastacl.main.dns_mode='doh'
uci set juliang_fastacl.main.dns_server='1.1.1.1'
uci set juliang_fastacl.main.dns_tls_server_name='cloudflare-dns.com'
uci set juliang_fastacl.main.dns_path='/dns-query'
uci set juliang_fastacl.main.version='V9-FIX1'
uci commit juliang_fastacl

echo "[INFO] removing every legacy A1..A10 -> WAN forwarding..."
changed=0
for sec in $(uci -q show firewall | sed -n "s/^firewall\.\([^.=]*\)=forwarding$/\1/p"); do
    src="$(uci -q get firewall.$sec.src 2>/dev/null || true)"
    dest="$(uci -q get firewall.$sec.dest 2>/dev/null || true)"
    case "$src:$dest" in
        a1:wan|a2:wan|a3:wan|a4:wan|a5:wan|a6:wan|a7:wan|a8:wan|a9:wan|a10:wan)
            echo "  delete firewall.$sec ($src -> $dest)"
            uci -q delete firewall.$sec
            changed=1
        ;;
    esac
done

for i in 1 2 3 4 5 6 7 8 9 10; do
    if [ "$(uci -q get firewall.a$i 2>/dev/null || true)" = "zone" ]; then
        uci set firewall.a$i.forward='REJECT'
        changed=1
    fi
done
if [ "$changed" -ne 0 ]; then
    uci commit firewall
    /etc/init.d/firewall restart >/dev/null 2>&1 || true
fi

echo "[INFO] disabling PassWall2 transparent dataplane..."
if uci -q get passwall2.@global[0] >/dev/null; then
    uci -q set passwall2.@global[0].enabled='0'
    uci -q set passwall2.@global[0].acl_enable='0'
    uci -q set passwall2.@global[0].socks_enabled='0'
    uci commit passwall2
fi
/etc/init.d/passwall2 stop >/dev/null 2>&1 || true
/etc/init.d/passwall2 disable >/dev/null 2>&1 || true

echo "[INFO] installing FastACL button into PassWall2 node list..."
/usr/bin/juliang-fastacl-luci-install >/tmp/juliang-fastacl/luci-fix1.log 2>&1 || {
    echo "[WARN] LuCI patch failed:"
    cat /tmp/juliang-fastacl/luci-fix1.log 2>/dev/null || true
}

echo "[INFO] discovering actual A1..A10 WiFi/network/subnets..."
/usr/bin/juliang-fastacl discover >/tmp/juliang-fastacl/discover-fix1.json 2>/tmp/juliang-fastacl/discover-fix1.log || {
    echo "[WARN] discovery failed:"
    cat /tmp/juliang-fastacl/discover-fix1.log 2>/dev/null || true
}

echo "[INFO] enabling Guardian and repairing dataplane..."
/etc/init.d/juliang-fastacl enable >/dev/null 2>&1 || true
/etc/init.d/juliang-fastacl restart >/dev/null 2>&1 || true
sleep 2
/usr/bin/juliang-fastacl repair >/tmp/juliang-fastacl/repair-fix1.log 2>&1 || {
    echo "[ERROR] FastACL repair failed:"
    cat /tmp/juliang-fastacl/repair-fix1.log 2>/dev/null || true
    exit 1
}
/usr/bin/juliang-fastacl save-state >/dev/null 2>&1 || true

rm -f /tmp/luci-indexcache
rm -rf /tmp/luci-modulecache /tmp/luci-templatecache
/etc/init.d/uhttpd restart >/dev/null 2>&1 || true

echo
echo "===== FastACL status ====="
/usr/bin/juliang-fastacl status

echo
echo "===== Guardian ====="
pgrep -af juliang-fastacl-guard 2>/dev/null || true

echo
echo "===== A->WAN forwarding (MUST BE EMPTY) ====="
found=0
for sec in $(uci -q show firewall | sed -n "s/^firewall\.\([^.=]*\)=forwarding$/\1/p"); do
    src="$(uci -q get firewall.$sec.src 2>/dev/null || true)"
    dest="$(uci -q get firewall.$sec.dest 2>/dev/null || true)"
    case "$src:$dest" in
        a1:wan|a2:wan|a3:wan|a4:wan|a5:wan|a6:wan|a7:wan|a8:wan|a9:wan|a10:wan)
            echo "UNSAFE: firewall.$sec $src -> $dest"
            found=1
        ;;
    esac
done
[ "$found" -eq 0 ] && echo "OK: no A1..A10 -> WAN forwarding"

echo
echo "===== kill-switch ====="
nft list table inet juliang_killswitch 2>/dev/null | sed -n '1,80p' || echo "MISSING"

echo
echo "===== FastACL UI marker ====="
grep -n 'JULIANG_FASTACL_V220' /usr/lib/lua/luci/view/passwall2/node_list/node_list.htm 2>/dev/null | head -n1 || echo "UI MARKER MISSING"

echo
echo "[OK] V9 Fix1 repair completed"

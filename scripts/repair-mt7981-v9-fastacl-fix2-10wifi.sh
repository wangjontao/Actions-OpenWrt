#!/bin/sh
set -eu

PIN="50451e78edea5a7d5e6ee4c9f8cf93c08da8b169"
BASE="https://raw.githubusercontent.com/wangjontao/Actions-OpenWrt/$PIN/profiles/fastacl-v9/root"
TMP="/tmp/jfa-v9-fix2-$$"
mkdir -p "$TMP" /tmp/juliang-fastacl /etc/juliang-fastacl
trap 'rm -rf "$TMP"' EXIT INT TERM

echo "=================================================="
echo " JuLiang FastACL V9 Fix2 - force runtime + 10WiFi migration"
echo "=================================================="

download_replace() {
    src="$1"; dst="$2"; mode="$3"
    tmp="$TMP/$(echo "$src" | tr '/' '_')"
    echo "[INFO] replace $dst"
    curl -4 -fL --connect-timeout 8 --max-time 60 --retry 2 -o "$tmp" "$BASE/$src"
    [ -s "$tmp" ]
    mkdir -p "$(dirname "$dst")"
    cp -af "$tmp" "$dst"
    chmod "$mode" "$dst"
}

# Always replace runtime. Fix1 only downloaded missing files, which allowed an
# older FastACL engine from the previous overlay/image to remain in place.
download_replace "usr/bin/juliang-fastacl" "/usr/bin/juliang-fastacl" 0755
download_replace "usr/bin/juliang-fastacl-guard" "/usr/bin/juliang-fastacl-guard" 0755
download_replace "usr/bin/juliang-fastacl-luci-install" "/usr/bin/juliang-fastacl-luci-install" 0755
download_replace "usr/libexec/juliang-fastacl-router.lua" "/usr/libexec/juliang-fastacl-router.lua" 0644
download_replace "usr/libexec/juliang-fastacl-relay.lua" "/usr/libexec/juliang-fastacl-relay.lua" 0644
download_replace "usr/libexec/juliang-fastacl-discover.lua" "/usr/libexec/juliang-fastacl-discover.lua" 0644
download_replace "usr/lib/lua/luci/controller/juliang_fastacl.lua" "/usr/lib/lua/luci/controller/juliang_fastacl.lua" 0644
download_replace "etc/init.d/juliang-fastacl" "/etc/init.d/juliang-fastacl" 0755
download_replace "etc/hotplug.d/iface/99-juliang-fastacl" "/etc/hotplug.d/iface/99-juliang-fastacl" 0755

grep -q 'juliang_killswitch' /usr/bin/juliang-fastacl || { echo "[ERROR] engine has no kill-switch"; exit 1; }
grep -q 'killswitch: loaded(fail-closed)' /usr/bin/juliang-fastacl || { echo "[ERROR] engine status has no kill-switch line"; exit 1; }
grep -q 'enforce_failclosed_firewall' /usr/bin/juliang-fastacl-guard || { echo "[ERROR] guardian is not Fix1+"; exit 1; }

# Preserve existing FastACL AP-node bindings if they exist; only refresh main.
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
uci set juliang_fastacl.main.version='V9-FIX2'
uci commit juliang_fastacl

echo "===== 10WiFi setup capability ====="
if ! grep -q '1 2 3 4 5 6 7 8 9 10' /usr/libexec/juliang-5wifi-setup 2>/dev/null; then
    echo "[ERROR] this image does not contain the 10WiFi setup script"
    echo "        /usr/libexec/juliang-5wifi-setup is not the V9 10WiFi version"
    exit 2
fi
echo "OK: firmware contains A1-A10 setup logic"

# V8/5WiFi preserved marker is the reason the V9 10WiFi setup never ran.
# Force the one-time 10WiFi migration once on this test router.
echo "[INFO] forcing A1-A10 migration (old V8 marker will not block it)..."
rm -f /etc/juliang-5wifi.done /etc/juliang-v9-fastacl-10wifi.done
/usr/libexec/juliang-5wifi-setup
touch /etc/juliang-v9-fastacl-10wifi.done

# Remove all unsafe A->WAN forwarding, named or anonymous.
echo "[INFO] enforcing fail-closed firewall..."
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
[ "$changed" -eq 0 ] || uci commit firewall
/etc/init.d/firewall restart >/dev/null 2>&1 || true

# PassWall2 = node database/UI only.
if uci -q get passwall2.@global[0] >/dev/null; then
    uci -q set passwall2.@global[0].enabled='0'
    uci -q set passwall2.@global[0].acl_enable='0'
    uci -q set passwall2.@global[0].socks_enabled='0'
    uci commit passwall2
fi
/etc/init.d/passwall2 stop >/dev/null 2>&1 || true
/etc/init.d/passwall2 disable >/dev/null 2>&1 || true

echo "[INFO] patching FastACL UI..."
/usr/bin/juliang-fastacl-luci-install >/tmp/juliang-fastacl/luci-fix2.log 2>&1 || {
    echo "[WARN] LuCI patch failed:"
    cat /tmp/juliang-fastacl/luci-fix2.log 2>/dev/null || true
}

echo "[INFO] discovering A1-A10..."
/usr/bin/juliang-fastacl discover >/tmp/juliang-fastacl/discover-fix2.json 2>/tmp/juliang-fastacl/discover-fix2.log || {
    echo "[ERROR] discovery failed:"
    cat /tmp/juliang-fastacl/discover-fix2.log 2>/dev/null || true
    exit 3
}

/etc/init.d/juliang-fastacl enable >/dev/null 2>&1 || true
/etc/init.d/juliang-fastacl restart >/dev/null 2>&1 || true
sleep 2

echo "[INFO] rebuilding FastACL dataplane and kill-switch..."
/usr/bin/juliang-fastacl repair >/tmp/juliang-fastacl/repair-fix2.log 2>&1 || {
    cat /tmp/juliang-fastacl/repair-fix2.log 2>/dev/null || true
    echo "[ERROR] FastACL repair failed"
    exit 4
}
/usr/bin/juliang-fastacl killswitch >/tmp/juliang-fastacl/killswitch-fix2.log 2>&1 || {
    cat /tmp/juliang-fastacl/killswitch-fix2.log 2>/dev/null || true
    echo "[ERROR] kill-switch load failed"
    exit 5
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
echo "===== discovered AP count ====="
COUNT="$(uci -q get juliang_fastacl.main.ap_count 2>/dev/null || echo 0)"
echo "$COUNT"
[ "$COUNT" = "10" ] || echo "[WARN] expected 10 APs, got $COUNT"

echo
echo "===== A1-A10 network ====="
for i in 1 2 3 4 5 6 7 8 9 10; do
    printf "A%-2s " "$i"
    uci -q get network.a$i.ipaddr 2>/dev/null || echo "MISSING"
done

echo
echo "===== A->WAN forwarding (MUST BE EMPTY) ====="
BAD=0
for sec in $(uci -q show firewall | sed -n "s/^firewall\.\([^.=]*\)=forwarding$/\1/p"); do
    src="$(uci -q get firewall.$sec.src 2>/dev/null || true)"
    dest="$(uci -q get firewall.$sec.dest 2>/dev/null || true)"
    case "$src:$dest" in
        a1:wan|a2:wan|a3:wan|a4:wan|a5:wan|a6:wan|a7:wan|a8:wan|a9:wan|a10:wan)
            echo "UNSAFE: firewall.$sec $src -> $dest"
            BAD=1
        ;;
    esac
done
[ "$BAD" -eq 0 ] && echo "OK: no A1..A10 -> WAN forwarding"

echo
echo "===== kill-switch ====="
if nft list table inet juliang_killswitch >/tmp/juliang-fastacl/killswitch-show.txt 2>/dev/null; then
    sed -n '1,100p' /tmp/juliang-fastacl/killswitch-show.txt
else
    echo "MISSING"
    exit 6
fi

echo
echo "===== policy ====="
ip rule show | grep -E '0x66|0x1' || true

echo
echo "===== FastACL UI marker ====="
grep -n 'JULIANG_FASTACL_V220' /usr/lib/lua/luci/view/passwall2/node_list/node_list.htm 2>/dev/null | head -n1 || {
    echo "UI MARKER MISSING"
    exit 7
}

echo
echo "[OK] V9 Fix2 completed: A1-A10 + FastACL + Guardian + fail-closed kill-switch"

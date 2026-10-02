#!/bin/sh
set -eu

PIN="8fd8c8ee0d4ce0a4f03d6ffafbedabf004acb698"
BASE="https://cdn.jsdelivr.net/gh/wangjontao/Actions-OpenWrt@$PIN/legacy/fastacl-2.3.9-iptables"
TMP="/tmp/jfa239-legacy-$$"
BK="/etc/juliang-fastacl/legacy-iptables-backup-$(date +%Y%m%d-%H%M%S)"

cleanup(){ rm -rf "$TMP" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

fetch(){
  src="$1"; dst="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -4 -fL --connect-timeout 10 --max-time 120 --retry 2 -o "$dst" "$BASE/$src"
  elif command -v wget >/dev/null 2>&1; then
    wget -O "$dst" "$BASE/$src"
  else
    echo "[ERROR] curl/wget not found" >&2
    exit 1
  fi
  [ -s "$dst" ]
}

echo "=================================================="
echo " JuLiang FastACL 2.3.9 Legacy iptables"
echo " fw3/iptables + sing-box 1.9.x compatibility"
echo "=================================================="

iptables -V 2>/dev/null | grep -qi legacy || {
  echo "[ERROR] this installer is only for iptables legacy firmware" >&2
  exit 1
}
command -v ip >/dev/null 2>&1 || { echo "[ERROR] ip command missing"; exit 1; }
command -v sing-box >/dev/null 2>&1 || { echo "[ERROR] sing-box missing"; exit 1; }

# Verify TPROXY target without touching live PREROUTING.
iptables -t mangle -N JFA_TPROXY_TEST >/dev/null 2>&1 || true
iptables -t mangle -F JFA_TPROXY_TEST >/dev/null 2>&1 || true
if ! iptables -t mangle -A JFA_TPROXY_TEST -p tcp -j TPROXY --on-port 12345 --tproxy-mark 0x66/0xff >/dev/null 2>&1; then
  iptables -t mangle -F JFA_TPROXY_TEST >/dev/null 2>&1 || true
  iptables -t mangle -X JFA_TPROXY_TEST >/dev/null 2>&1 || true
  echo "[ERROR] iptables TPROXY target is unavailable" >&2
  exit 1
fi
iptables -t mangle -F JFA_TPROXY_TEST >/dev/null 2>&1 || true
iptables -t mangle -X JFA_TPROXY_TEST >/dev/null 2>&1 || true

mkdir -p "$TMP/usr/bin" "$TMP/usr/libexec" "$TMP/usr/lib/lua/luci/controller" "$BK"

fetch usr/bin/juliang-fastacl "$TMP/usr/bin/juliang-fastacl"
fetch usr/libexec/juliang-fastacl-router.lua "$TMP/usr/libexec/juliang-fastacl-router.lua"
fetch usr/lib/lua/luci/controller/juliang_fastacl.lua "$TMP/usr/lib/lua/luci/controller/juliang_fastacl.lua"

sh -n "$TMP/usr/bin/juliang-fastacl"
lua -e 'assert(loadfile("'"$TMP"'/usr/libexec/juliang-fastacl-router.lua"))'
lua -e 'assert(loadfile("'"$TMP"'/usr/lib/lua/luci/controller/juliang_fastacl.lua"))'

cp -af /usr/bin/juliang-fastacl "$BK/juliang-fastacl" 2>/dev/null || true
cp -af /usr/libexec/juliang-fastacl-router.lua "$BK/juliang-fastacl-router.lua" 2>/dev/null || true
cp -af /usr/lib/lua/luci/controller/juliang_fastacl.lua "$BK/juliang_fastacl.lua" 2>/dev/null || true

/etc/init.d/juliang-fastacl stop >/dev/null 2>&1 || true

install -m0755 "$TMP/usr/bin/juliang-fastacl" /usr/bin/juliang-fastacl
install -m0644 "$TMP/usr/libexec/juliang-fastacl-router.lua" /usr/libexec/juliang-fastacl-router.lua
install -m0644 "$TMP/usr/lib/lua/luci/controller/juliang_fastacl.lua" /usr/lib/lua/luci/controller/juliang_fastacl.lua

rm -f /tmp/luci-indexcache /tmp/luci-indexcache.* 2>/dev/null || true
rm -rf /tmp/luci-modulecache /tmp/luci-templatecache 2>/dev/null || true

echo "[INFO] sing-box: $(sing-box version 2>/dev/null | head -n1)"
echo "[INFO] rediscover wireless..."
/usr/bin/juliang-fastacl discover >/tmp/jfa239-legacy-discover.json 2>/tmp/jfa239-legacy-discover.log

echo "[INFO] build legacy iptables dataplane..."
if ! /usr/bin/juliang-fastacl repair >/tmp/jfa239-legacy-repair.log 2>&1; then
  echo "[ERROR] repair failed"
  cat /tmp/jfa239-legacy-repair.log 2>/dev/null || true
  echo "[INFO] backup: $BK"
  exit 1
fi

/usr/bin/juliang-fastacl save-state >/dev/null 2>&1 || true
/etc/init.d/juliang-fastacl enable >/dev/null 2>&1 || true
/etc/init.d/juliang-fastacl restart >/dev/null 2>&1 || true
/etc/init.d/rpcd restart >/dev/null 2>&1 || true
/etc/init.d/uhttpd restart >/dev/null 2>&1 || true

sleep 2

echo
echo "===== FastACL status ====="
/usr/bin/juliang-fastacl status

echo
echo "===== iptables TProxy ====="
iptables -t mangle -S JULIANG_FASTACL 2>/dev/null | head -40

echo
echo "===== kill-switch ====="
iptables -t filter -S JULIANG_KILLSWITCH 2>/dev/null

/usr/bin/juliang-fastacl status | grep -q '^router: running$' || {
  echo "[ERROR] router is not running"
  cat /tmp/juliang-fastacl/router.log 2>/dev/null || true
  exit 1
}
/usr/bin/juliang-fastacl status | grep -q '^killswitch: loaded' || {
  echo "[ERROR] legacy kill-switch is not loaded"
  exit 1
}

echo
echo "[OK] Legacy iptables compatibility installed"
echo "[OK] FastACL router running"
echo "[OK] iptables TPROXY loaded"
echo "[OK] iptables fail-closed kill-switch loaded"
echo "[INFO] backup: $BK"

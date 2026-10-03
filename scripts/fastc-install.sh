#!/bin/sh
set -eu

PIN="55dc84c2b15cc7daef27c743705cdad422e27c58"
BASE="https://cdn.jsdelivr.net/gh/wangjontao/Actions-OpenWrt@$PIN/profiles/fastc-v010/root"
TMP="/tmp/fastc011-$$"
BACKUP="/etc/fastc/install-backup-$(date +%Y%m%d-%H%M%S)"

cleanup(){ rm -rf "$TMP" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

fetch_one(){
  url="$1"
  out="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -4 -fL --connect-timeout 8 --max-time 120 --retry 3 -o "$out" "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget -O "$out" "$url"
  else
    echo "[ERROR] curl/wget not found" >&2
    exit 1
  fi
}

echo "=================================================="
echo " FastC 0.1.1-dev Installer"
echo " import fix + core detection + mode status"
echo " jsDelivr transport / no raw.githubusercontent"
echo "=================================================="

mkdir -p "$TMP" "$BACKUP" /etc/fastc \
  /usr/lib/lua/luci/controller \
  /usr/lib/lua/luci/view/fastc \
  /usr/libexec \
  /usr/share/rpcd/acl.d

for p in \
  /etc/config/fastc \
  /usr/lib/lua/luci/controller/fastc.lua \
  /usr/lib/lua/luci/view/fastc/console.htm \
  /usr/libexec/fastc-import.lua \
  /usr/share/rpcd/acl.d/fastc.json
 do
  [ -f "$p" ] || continue
  d="$BACKUP$(dirname "$p")"
  mkdir -p "$d"
  cp -af "$p" "$d/"
 done

fetch_one "$BASE/etc/config/fastc" "$TMP/fastc.config"
fetch_one "$BASE/usr/lib/lua/luci/controller/fastc.lua" "$TMP/fastc.lua"
fetch_one "$BASE/usr/lib/lua/luci/view/fastc/console.htm" "$TMP/console.htm"
fetch_one "$BASE/usr/libexec/fastc-import.lua" "$TMP/fastc-import.lua"
fetch_one "$BASE/usr/share/rpcd/acl.d/fastc.json" "$TMP/fastc.json"

# Validate all downloads before touching the live LuCI files.
test -s "$TMP/fastc.config"
test -s "$TMP/fastc.lua"
test -s "$TMP/console.htm"
test -s "$TMP/fastc-import.lua"
test -s "$TMP/fastc.json"
grep -q 'module("luci.controller.fastc"' "$TMP/fastc.lua"
grep -q 'FastC 0.1.1' "$TMP/console.htm"
grep -q 's = s:gsub("%+", " ")' "$TMP/fastc-import.lua"
grep -q 'core_present' "$TMP/fastc.lua"

cp -af "$TMP/fastc.config" /etc/config/fastc
cp -af "$TMP/fastc.lua" /usr/lib/lua/luci/controller/fastc.lua
cp -af "$TMP/console.htm" /usr/lib/lua/luci/view/fastc/console.htm
cp -af "$TMP/fastc-import.lua" /usr/libexec/fastc-import.lua
cp -af "$TMP/fastc.json" /usr/share/rpcd/acl.d/fastc.json
chmod 0755 /usr/libexec/fastc-import.lua
chmod 0644 /etc/config/fastc /usr/lib/lua/luci/controller/fastc.lua \
  /usr/lib/lua/luci/view/fastc/console.htm /usr/share/rpcd/acl.d/fastc.json

[ -f /etc/fastc/nodes.json ] || echo '[]' > /etc/fastc/nodes.json

rm -f /tmp/luci-indexcache /tmp/luci-indexcache.* 2>/dev/null || true
rm -rf /tmp/luci-modulecache /tmp/luci-templatecache 2>/dev/null || true
/etc/init.d/rpcd restart >/dev/null 2>&1 || true
/etc/init.d/uhttpd restart >/dev/null 2>&1 || true

echo
CORE=""
command -v mihomo >/dev/null 2>&1 && CORE="$(command -v mihomo)"
[ -n "$CORE" ] || { command -v clash >/dev/null 2>&1 && CORE="$(command -v clash)"; }
[ -n "$CORE" ] || [ ! -x /etc/openclash/core/clash_meta ] || CORE="/etc/openclash/core/clash_meta"
[ -n "$CORE" ] || [ ! -x /etc/openclash/core/clash ] || CORE="/etc/openclash/core/clash"
[ -n "$CORE" ] || [ ! -x /usr/bin/clash_meta ] || CORE="/usr/bin/clash_meta"

if [ -n "$CORE" ]; then
  echo "[OK] mihomo-compatible core detected: $CORE"
  "$CORE" -v 2>/dev/null | head -n1 || true
else
  echo "[WARN] mihomo-compatible core not detected yet; node import still works"
fi

echo "[OK] FastC 0.1.1-dev UI installed"
echo "[OK] Import callback fixed"
echo "[OK] Lua URL decoder fixed"
echo "[OK] FastACL/FastC mode status enabled"
echo "[OK] Node database: /etc/fastc/nodes.json"
echo "[INFO] LuCI: Services -> FastC"
echo "[INFO] Backup: $BACKUP"
echo "[INFO] FastC dataplane is not enabled yet; FastACL remains the active mode."

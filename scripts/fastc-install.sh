#!/bin/sh
set -eu

PIN="ced092c1281d0ea6a4e17ba7012e356761b7919b"
BASE="https://cdn.jsdelivr.net/gh/wangjontao/Actions-OpenWrt@$PIN/profiles/fastc-v010/root"
TMP="/tmp/fastc012-$$"
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

find_core(){
  CORE=""
  command -v mihomo >/dev/null 2>&1 && CORE="$(command -v mihomo)"
  [ -n "$CORE" ] || { command -v clash >/dev/null 2>&1 && CORE="$(command -v clash)"; }
  [ -n "$CORE" ] || [ ! -x /etc/openclash/core/clash_meta ] || CORE="/etc/openclash/core/clash_meta"
  [ -n "$CORE" ] || [ ! -x /etc/openclash/core/clash ] || CORE="/etc/openclash/core/clash"
  [ -n "$CORE" ] || [ ! -x /usr/bin/clash_meta ] || CORE="/usr/bin/clash_meta"
}

echo "=================================================="
echo " FastC 0.1.2-dev Installer"
echo " node import + verified mihomo Core Manager"
echo " FastACL remains active; no traffic handoff yet"
echo "=================================================="

mkdir -p "$TMP" "$BACKUP" /etc/fastc \
  /usr/bin \
  /usr/lib/lua/luci/controller \
  /usr/lib/lua/luci/view/fastc \
  /usr/libexec \
  /usr/share/rpcd/acl.d

for p in \
  /etc/config/fastc \
  /usr/bin/fastc-core \
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
fetch_one "$BASE/usr/bin/fastc-core" "$TMP/fastc-core"
fetch_one "$BASE/usr/lib/lua/luci/controller/fastc.lua" "$TMP/fastc.lua"
fetch_one "$BASE/usr/lib/lua/luci/view/fastc/console.htm" "$TMP/console.htm"
fetch_one "$BASE/usr/libexec/fastc-import.lua" "$TMP/fastc-import.lua"
fetch_one "$BASE/usr/share/rpcd/acl.d/fastc.json" "$TMP/fastc.json"

# Validate every text component before replacing live files.
test -s "$TMP/fastc.config"
test -s "$TMP/fastc-core"
test -s "$TMP/fastc.lua"
test -s "$TMP/console.htm"
test -s "$TMP/fastc-import.lua"
test -s "$TMP/fastc.json"
grep -q "option version '0.1.2-dev'" "$TMP/fastc.config"
grep -q 'MIHOMO_VERSION="1.19.32"' "$TMP/fastc-core"
grep -q 'module("luci.controller.fastc"' "$TMP/fastc.lua"
grep -q 'action == "install_core"' "$TMP/fastc.lua"
grep -q 'FastC 0.1.2' "$TMP/console.htm"
grep -q 's = s:gsub("%+", " ")' "$TMP/fastc-import.lua"

# Preserve existing node database. FastC config is still development-only and
# defaults to FastACL mode, so installing 0.1.2 cannot take over traffic.
cp -af "$TMP/fastc.config" /etc/config/fastc
cp -af "$TMP/fastc-core" /usr/bin/fastc-core
cp -af "$TMP/fastc.lua" /usr/lib/lua/luci/controller/fastc.lua
cp -af "$TMP/console.htm" /usr/lib/lua/luci/view/fastc/console.htm
cp -af "$TMP/fastc-import.lua" /usr/libexec/fastc-import.lua
cp -af "$TMP/fastc.json" /usr/share/rpcd/acl.d/fastc.json
chmod 0755 /usr/bin/fastc-core /usr/libexec/fastc-import.lua
chmod 0644 /etc/config/fastc /usr/lib/lua/luci/controller/fastc.lua \
  /usr/lib/lua/luci/view/fastc/console.htm /usr/share/rpcd/acl.d/fastc.json

[ -f /etc/fastc/nodes.json ] || echo '[]' > /etc/fastc/nodes.json

find_core
if [ -z "$CORE" ]; then
  echo
  echo "[INFO] No mihomo-compatible core detected. Installing official verified core..."
  if /usr/bin/fastc-core install; then
    echo "[OK] FastC mihomo core installation completed"
  else
    echo "[WARN] Automatic mihomo download failed. FastC UI/import is still usable."
    echo "[WARN] Open FastC and click '安装 mihomo 内核' to retry."
  fi
fi

rm -f /tmp/luci-indexcache /tmp/luci-indexcache.* 2>/dev/null || true
rm -rf /tmp/luci-modulecache /tmp/luci-templatecache 2>/dev/null || true
/etc/init.d/rpcd restart >/dev/null 2>&1 || true
/etc/init.d/uhttpd restart >/dev/null 2>&1 || true

echo
find_core
if [ -n "$CORE" ]; then
  echo "[OK] mihomo-compatible core detected: $CORE"
  "$CORE" -v 2>/dev/null | head -n1 || true
else
  echo "[WARN] mihomo-compatible core is still missing"
fi

echo "[OK] FastC 0.1.2-dev UI installed"
echo "[OK] Official mihomo Core Manager installed"
echo "[OK] Node database preserved: /etc/fastc/nodes.json"
echo "[INFO] LuCI: Services -> FastC"
echo "[INFO] Backup: $BACKUP"
echo "[INFO] Current traffic mode remains FastACL. Installing the core does not start FastC dataplane."

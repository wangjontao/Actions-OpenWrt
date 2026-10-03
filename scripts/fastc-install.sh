#!/bin/sh
set -eu

PIN="7e4a6b51184d9c10cc3c75d8a4715e4523e6b0ac"
BASE="https://cdn.jsdelivr.net/gh/wangjontao/Actions-OpenWrt@$PIN/profiles/fastc-v010/root"
TMP="/tmp/fastc013-$$"
BACKUP="/etc/fastc/install-backup-$(date +%Y%m%d-%H%M%S)"

cleanup(){ rm -rf "$TMP" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

fetch_one(){
  url="$1"; out="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -4 -fL --connect-timeout 8 --max-time 120 --retry 3 -o "$out" "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget -O "$out" "$url"
  else
    echo "[ERROR] curl/wget not found" >&2; exit 1
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
echo " FastC 0.1.3-dev Installer"
echo " A1-A20 assignment + mihomo manager + real delay test"
echo " FastACL remains the traffic mode"
echo "=================================================="

mkdir -p "$TMP" "$BACKUP" /etc/fastc /usr/bin /etc/init.d \
  /usr/lib/lua/luci/controller /usr/lib/lua/luci/view/fastc /usr/libexec /usr/share/rpcd/acl.d

for p in \
  /etc/config/fastc \
  /usr/bin/fastc-core \
  /etc/init.d/fastc \
  /usr/lib/lua/luci/controller/fastc.lua \
  /usr/lib/lua/luci/view/fastc/console.htm \
  /usr/libexec/fastc-import.lua \
  /usr/libexec/fastc-generate.lua \
  /usr/share/rpcd/acl.d/fastc.json
 do
  [ -f "$p" ] || continue
  d="$BACKUP$(dirname "$p")"; mkdir -p "$d"; cp -af "$p" "$d/"
 done

fetch_one "$BASE/etc/config/fastc" "$TMP/fastc.config"
fetch_one "$BASE/usr/bin/fastc-core" "$TMP/fastc-core"
fetch_one "$BASE/etc/init.d/fastc" "$TMP/fastc.init"
fetch_one "$BASE/usr/lib/lua/luci/controller/fastc.lua" "$TMP/fastc.lua"
fetch_one "$BASE/usr/lib/lua/luci/view/fastc/console.htm" "$TMP/console.htm"
fetch_one "$BASE/usr/libexec/fastc-import.lua" "$TMP/fastc-import.lua"
fetch_one "$BASE/usr/libexec/fastc-generate.lua" "$TMP/fastc-generate.lua"
fetch_one "$BASE/usr/share/rpcd/acl.d/fastc.json" "$TMP/fastc.json"

test -s "$TMP/fastc.config"; test -s "$TMP/fastc-core"; test -s "$TMP/fastc.init"
test -s "$TMP/fastc.lua"; test -s "$TMP/console.htm"; test -s "$TMP/fastc-import.lua"
test -s "$TMP/fastc-generate.lua"; test -s "$TMP/fastc.json"
grep -q "option version '0.1.3-dev'" "$TMP/fastc.config"
grep -q 'MIHOMO_VERSION="1.19.32"' "$TMP/fastc-core"
grep -q 'action == "assign"' "$TMP/fastc.lua"
grep -q 'action == "test"' "$TMP/fastc.lua"
grep -q 'FastC 0.1.3' "$TMP/console.htm"
grep -q 'FASTC-A' "$TMP/fastc-generate.lua"

# Preserve node database and all imported nodes/assignments/test history.
cp -af "$TMP/fastc.config" /etc/config/fastc
cp -af "$TMP/fastc-core" /usr/bin/fastc-core
cp -af "$TMP/fastc.init" /etc/init.d/fastc
cp -af "$TMP/fastc.lua" /usr/lib/lua/luci/controller/fastc.lua
cp -af "$TMP/console.htm" /usr/lib/lua/luci/view/fastc/console.htm
cp -af "$TMP/fastc-import.lua" /usr/libexec/fastc-import.lua
cp -af "$TMP/fastc-generate.lua" /usr/libexec/fastc-generate.lua
cp -af "$TMP/fastc.json" /usr/share/rpcd/acl.d/fastc.json
chmod 0755 /usr/bin/fastc-core /etc/init.d/fastc /usr/libexec/fastc-import.lua /usr/libexec/fastc-generate.lua
chmod 0644 /etc/config/fastc /usr/lib/lua/luci/controller/fastc.lua /usr/lib/lua/luci/view/fastc/console.htm /usr/share/rpcd/acl.d/fastc.json

[ -f /etc/fastc/nodes.json ] || echo '[]' > /etc/fastc/nodes.json

find_core
if [ -z "$CORE" ]; then
  echo "[INFO] mihomo core missing; installing verified official core..."
  /usr/bin/fastc-core install || echo "[WARN] core install failed; retry later from FastC UI"
fi

# Generate the management/test config and start mihomo without TProxy takeover.
if lua /usr/libexec/fastc-generate.lua >/tmp/fastc-generate.json 2>/tmp/fastc-generate.log; then
  if /usr/bin/mihomo -t -d /etc/fastc -f /etc/fastc/config.yaml >/tmp/fastc-mihomo-check.log 2>&1; then
    /etc/init.d/fastc enable >/dev/null 2>&1 || true
    /etc/init.d/fastc restart >/tmp/fastc-start.log 2>&1 || true
    sleep 1
  else
    echo "[WARN] mihomo config validation failed:"
    cat /tmp/fastc-mihomo-check.log 2>/dev/null || true
  fi
else
  echo "[WARN] FastC config generation failed:"
  cat /tmp/fastc-generate.log 2>/dev/null || true
fi

rm -f /tmp/luci-indexcache /tmp/luci-indexcache.* 2>/dev/null || true
rm -rf /tmp/luci-modulecache /tmp/luci-templatecache 2>/dev/null || true
/etc/init.d/rpcd restart >/dev/null 2>&1 || true
/etc/init.d/uhttpd restart >/dev/null 2>&1 || true

echo
find_core
[ -n "$CORE" ] && { echo "[OK] mihomo core: $CORE"; "$CORE" -v 2>/dev/null | head -n1 || true; }
if /etc/init.d/fastc running >/dev/null 2>&1; then
  echo "[OK] FastC mihomo management/test core is running"
else
  echo "[WARN] FastC management core is not running; check /tmp/fastc-mihomo-check.log"
fi
echo "[OK] FastC 0.1.3-dev UI installed"
echo "[OK] A1-A20 strategy assignment enabled"
echo "[OK] Per-node real mihomo delay test enabled"
echo "[OK] Detect-all enabled"
echo "[OK] Node database preserved: /etc/fastc/nodes.json"
echo "[INFO] Current traffic mode is still FastACL; FastC 0.1.3 only runs management/testing core."
echo "[INFO] LuCI: Services -> FastC"
echo "[INFO] Backup: $BACKUP"

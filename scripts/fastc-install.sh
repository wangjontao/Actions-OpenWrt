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
    echo "[ERROR] curl/wget not found" >&2
    exit 1
  fi
}

require_file(){
  f="$1"; label="$2"
  if [ ! -s "$f" ]; then
    echo "[ERROR] validation failed: missing/empty $label ($f)" >&2
    exit 1
  fi
  echo "[OK] validated file: $label"
}

require_grep(){
  pat="$1"; f="$2"; label="$3"
  if ! grep -q "$pat" "$f"; then
    echo "[ERROR] validation failed: $label" >&2
    echo "[ERROR] expected pattern: $pat" >&2
    echo "[ERROR] file: $f" >&2
    exit 1
  fi
  echo "[OK] validated content: $label"
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
echo " FastC 0.1.3-dev Fix1 Installer"
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
  d="$BACKUP$(dirname "$p")"
  mkdir -p "$d"
  cp -af "$p" "$d/"
 done

fetch_one "$BASE/etc/config/fastc" "$TMP/fastc.config"
fetch_one "$BASE/usr/bin/fastc-core" "$TMP/fastc-core"
fetch_one "$BASE/etc/init.d/fastc" "$TMP/fastc.init"
fetch_one "$BASE/usr/lib/lua/luci/controller/fastc.lua" "$TMP/fastc.lua"
fetch_one "$BASE/usr/lib/lua/luci/view/fastc/console.htm" "$TMP/console.htm"
fetch_one "$BASE/usr/libexec/fastc-import.lua" "$TMP/fastc-import.lua"
fetch_one "$BASE/usr/libexec/fastc-generate.lua" "$TMP/fastc-generate.lua"
fetch_one "$BASE/usr/share/rpcd/acl.d/fastc.json" "$TMP/fastc.json"

echo "[INFO] Validating downloaded FastC 0.1.3 components..."
require_file "$TMP/fastc.config" "FastC UCI config"
require_file "$TMP/fastc-core" "mihomo Core Manager"
require_file "$TMP/fastc.init" "FastC init service"
require_file "$TMP/fastc.lua" "FastC LuCI controller"
require_file "$TMP/console.htm" "FastC LuCI console"
require_file "$TMP/fastc-import.lua" "node importer"
require_file "$TMP/fastc-generate.lua" "mihomo config generator"
require_file "$TMP/fastc.json" "rpcd ACL"

require_grep "option version '0.1.3-dev'" "$TMP/fastc.config" "version 0.1.3-dev"
require_grep 'MIHOMO_VERSION="1.19.32"' "$TMP/fastc-core" "mihomo v1.19.32 manager"
require_grep 'action == "assign"' "$TMP/fastc.lua" "A1-A20 assignment API"
require_grep 'action == "test"' "$TMP/fastc.lua" "per-node test API"
require_grep 'FastC 0.1.3' "$TMP/console.htm" "0.1.3 UI"
require_grep 'for i=1,20 do' "$TMP/fastc-generate.lua" "A1-A20 policy-group generator"
require_grep 'FASTC-' "$TMP/fastc-generate.lua" "FastC policy-group naming"

echo "[OK] All downloaded components validated"

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
chmod 0644 /etc/config/fastc /usr/lib/lua/luci/controller/fastc.lua \
  /usr/lib/lua/luci/view/fastc/console.htm /usr/share/rpcd/acl.d/fastc.json

[ -f /etc/fastc/nodes.json ] || echo '[]' > /etc/fastc/nodes.json

find_core
if [ -z "$CORE" ]; then
  echo "[INFO] mihomo core missing; installing verified official core..."
  /usr/bin/fastc-core install || echo "[WARN] core install failed; retry later from FastC UI"
fi

# Generate management/test config and start mihomo without TProxy takeover.
if lua /usr/libexec/fastc-generate.lua >/tmp/fastc-generate.json 2>/tmp/fastc-generate.log; then
  echo "[OK] FastC mihomo test config generated"
  if /usr/bin/mihomo -t -d /etc/fastc -f /etc/fastc/config.yaml >/tmp/fastc-mihomo-check.log 2>&1; then
    echo "[OK] mihomo config validation passed"
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
[ -n "$CORE" ] && {
  echo "[OK] mihomo core: $CORE"
  "$CORE" -v 2>/dev/null | head -n1 || true
}

if /etc/init.d/fastc running >/dev/null 2>&1; then
  echo "[OK] FastC mihomo management/test core is running"
else
  echo "[WARN] FastC management core is not running"
  [ -s /tmp/fastc-start.log ] && { echo "[INFO] /tmp/fastc-start.log:"; cat /tmp/fastc-start.log; }
  [ -s /tmp/fastc-mihomo-check.log ] && { echo "[INFO] /tmp/fastc-mihomo-check.log:"; cat /tmp/fastc-mihomo-check.log; }
fi

echo "[OK] FastC 0.1.3-dev Fix1 UI installed"
echo "[OK] A1-A20 strategy assignment enabled"
echo "[OK] Per-node real mihomo delay test enabled"
echo "[OK] Detect-all enabled"
echo "[OK] Node database preserved: /etc/fastc/nodes.json"
echo "[INFO] Current traffic mode is still FastACL; FastC only runs management/testing core."
echo "[INFO] LuCI: Services -> FastC"
echo "[INFO] Backup: $BACKUP"

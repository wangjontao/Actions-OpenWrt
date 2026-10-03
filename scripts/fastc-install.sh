#!/bin/sh
set -eu
PIN="5925167975f9b3aaf7f0f32cbed9d5fc212412a8"
BASE="https://cdn.jsdelivr.net/gh/wangjontao/Actions-OpenWrt@$PIN/profiles/fastc-v010/root"
TMP="/tmp/fastc014-$$"
BACKUP="/etc/fastc/install-backup-$(date +%Y%m%d-%H%M%S)"
OLD_MODE="$(uci -q get fastc.main.mode 2>/dev/null || echo fastacl)"
OLD_ENABLED="$(uci -q get fastc.main.enabled 2>/dev/null || echo 0)"
trap 'rm -rf "$TMP" 2>/dev/null || true' EXIT INT TERM
get(){ mkdir -p "$(dirname "$2")"; curl -4 -fL --connect-timeout 8 --max-time 120 --retry 3 -o "$2" "$BASE/$1"; }

echo "=================================================="
echo " FastC 0.1.4-dev Installer"
echo " TProxy + A1-A20 + chain + safe FastACL handoff"
echo "=================================================="
mkdir -p "$TMP" "$BACKUP" /etc/fastc

FILES="etc/config/fastc usr/bin/fastc-core usr/bin/fastc-dataplane usr/bin/fastc-mode etc/init.d/fastc usr/lib/lua/luci/controller/fastc.lua usr/lib/lua/luci/view/fastc/console.htm usr/libexec/fastc-import.lua usr/libexec/fastc-generate.lua usr/share/rpcd/acl.d/fastc.json"
for f in $FILES; do
  [ -f "/$f" ] && { mkdir -p "$BACKUP/$(dirname "$f")"; cp -af "/$f" "$BACKUP/$f"; } || true
  get "$f" "$TMP/$f"
  [ -s "$TMP/$f" ] || { echo "[ERROR] empty component: $f" >&2; exit 1; }
  echo "[OK] downloaded: $f"
done

grep -q "option version '0.1.4-dev'" "$TMP/etc/config/fastc"
grep -q 'dialer-proxy:' "$TMP/usr/libexec/fastc-generate.lua"
grep -q 'SRC-IP-CIDR' "$TMP/usr/libexec/fastc-generate.lua"
grep -q 'fastc_killswitch' "$TMP/usr/bin/fastc-dataplane"
grep -q 'restore_fastacl' "$TMP/usr/bin/fastc-mode"
grep -q 'switch_mode' "$TMP/usr/lib/lua/luci/controller/fastc.lua"
grep -q 'set_chain' "$TMP/usr/lib/lua/luci/controller/fastc.lua"
grep -q 'FastC 0.1.4' "$TMP/usr/lib/lua/luci/view/fastc/console.htm"
sh -n "$TMP/usr/bin/fastc-core"
sh -n "$TMP/usr/bin/fastc-dataplane"
sh -n "$TMP/usr/bin/fastc-mode"
lua -e 'assert(loadfile(arg[1]))' "$TMP/usr/lib/lua/luci/controller/fastc.lua"
lua -e 'assert(loadfile(arg[1]))' "$TMP/usr/libexec/fastc-generate.lua"
echo "[OK] 0.1.4 components validated"

for f in $FILES; do mkdir -p "/$(dirname "$f")"; cp -af "$TMP/$f" "/$f"; done
chmod 0755 /usr/bin/fastc-core /usr/bin/fastc-dataplane /usr/bin/fastc-mode /etc/init.d/fastc /usr/libexec/fastc-import.lua /usr/libexec/fastc-generate.lua
chmod 0644 /etc/config/fastc /usr/lib/lua/luci/controller/fastc.lua /usr/lib/lua/luci/view/fastc/console.htm /usr/share/rpcd/acl.d/fastc.json
[ -f /etc/fastc/nodes.json ] || echo '[]' > /etc/fastc/nodes.json
[ -f /etc/fastc/groups.json ] || echo '{}' > /etc/fastc/groups.json
uci set fastc.main.version='0.1.4-dev'
uci set fastc.main.mode="$OLD_MODE"
uci set fastc.main.enabled="$OLD_ENABLED"
uci commit fastc

[ -x /usr/bin/mihomo ] || /usr/bin/fastc-core install || true
lua /usr/libexec/fastc-generate.lua >/tmp/fastc-generate.json 2>/tmp/fastc-generate.log || { cat /tmp/fastc-generate.log; exit 1; }
/usr/bin/mihomo -t -d /etc/fastc -f /etc/fastc/config.yaml >/tmp/fastc-mihomo-check.log 2>&1 || { cat /tmp/fastc-mihomo-check.log; exit 1; }
/etc/init.d/fastc enable >/dev/null 2>&1 || true
if [ "$OLD_MODE" = "fastc" ]; then /usr/bin/fastc-mode fastc; else /etc/init.d/fastc restart >/dev/null 2>&1 || true; fi
rm -f /tmp/luci-indexcache /tmp/luci-indexcache.* 2>/dev/null || true
rm -rf /tmp/luci-modulecache /tmp/luci-templatecache 2>/dev/null || true
/etc/init.d/rpcd restart >/dev/null 2>&1 || true
/etc/init.d/uhttpd restart >/dev/null 2>&1 || true

echo "[OK] FastC 0.1.4-dev installed"
echo "[OK] A1-A20 selector / dialer chain / TProxy / fail-closed / safe rollback enabled"
echo "[INFO] Traffic mode preserved: $OLD_MODE"
echo "[INFO] Backup: $BACKUP"

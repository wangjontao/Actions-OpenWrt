#!/bin/sh
set -eu

PIN="9877fa1556aee24abd9cd18ed11cb33569e59ba2"
ARCHIVE="https://codeload.github.com/wangjontao/Actions-OpenWrt/tar.gz/$PIN"
TMP="/tmp/jfa24-full-$$"
TGZ="/tmp/jfa24-full-$$.tar.gz"
BACKUP="/etc/juliang-fastacl/v2.4-full-backup-$(date +%Y%m%d-%H%M%S)"

cleanup() {
  rm -rf "$TMP" "$TGZ" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

fetch_archive() {
  if command -v curl >/dev/null 2>&1; then
    curl -4 --http1.1 -fL --connect-timeout 15 --max-time 180 --retry 5 --retry-delay 2 -o "$TGZ" "$ARCHIVE"
  elif command -v wget >/dev/null 2>&1; then
    wget -O "$TGZ" "$ARCHIVE"
  else
    echo "[ERROR] curl/wget not found" >&2
    exit 1
  fi
}

need_file() {
  [ -s "$1" ] || { echo "[ERROR] required file missing: $1" >&2; exit 1; }
}

echo "=================================================="
echo " JuLiang FastACL 2.4 Stable - Full Installer"
echo " FastACL + Operator UI + SSH 20022"
echo " SK5/HTTP import + 403 fix + rename/delete/batch-delete"
echo "=================================================="

mkdir -p "$TMP" "$BACKUP"

if ! command -v nft >/dev/null 2>&1; then
  echo "[INFO] nft command missing; installing nftables userspace..."
  command -v opkg >/dev/null 2>&1 || { echo "[ERROR] nft missing and opkg unavailable" >&2; exit 1; }
  opkg update
  opkg install nftables-json >/dev/null 2>&1 || opkg install nftables-nojson
fi
command -v nft >/dev/null 2>&1 || { echo "[ERROR] nft installation failed" >&2; exit 1; }

# FastACL 2.4 UI upgrade currently uses GitHub API via curl.
if ! command -v curl >/dev/null 2>&1; then
  command -v opkg >/dev/null 2>&1 || { echo "[ERROR] curl missing and opkg unavailable" >&2; exit 1; }
  echo "[INFO] curl missing; installing curl..."
  opkg update
  opkg install curl
fi

fetch_archive
[ -s "$TGZ" ] || { echo "[ERROR] archive download failed" >&2; exit 1; }
tar -xzf "$TGZ" -C "$TMP"

SRC="$(find "$TMP" -type d -path '*/profiles/fastacl-v9/root' | head -n1)"
PW2_FIX="$(find "$TMP" -type f -path '*/scripts/repair-passwall2-sk5-http-import.sh' | head -n1)"
IMPORT403_FIX="$(find "$TMP" -type f -path '*/scripts/repair-fastacl-console-import-403.sh' | head -n1)"
V24_UPGRADE="$(find "$TMP" -type f -path '*/scripts/upgrade-juliang-fastacl-v2.4.sh' | head -n1)"

[ -n "$SRC" ] && [ -d "$SRC" ] || { echo "[ERROR] FastACL profile root not found" >&2; exit 1; }
need_file "$PW2_FIX"
need_file "$IMPORT403_FIX"
need_file "$V24_UPGRADE"

sh -n "$PW2_FIX"
sh -n "$IMPORT403_FIX"
sh -n "$V24_UPGRADE"

# Preserve live configuration/state before replacing program files.
cp -af /etc/config/juliang_fastacl "$BACKUP/juliang_fastacl" 2>/dev/null || true
cp -af /etc/config/passwall2 "$BACKUP/passwall2" 2>/dev/null || true
cp -af /etc/config/dropbear "$BACKUP/dropbear" 2>/dev/null || true
cp -af /etc/config/rpcd "$BACKUP/rpcd" 2>/dev/null || true
cp -af /usr/lib/lua/luci/controller/juliang_fastacl.lua "$BACKUP/juliang_fastacl.lua" 2>/dev/null || true
cp -af /usr/lib/lua/luci/view/juliang_fastacl/console.htm "$BACKUP/console.htm" 2>/dev/null || true
cp -af /www/luci-static/resources/juliang-fastacl-v24.js "$BACKUP/juliang-fastacl-v24.js" 2>/dev/null || true

cp -af "$SRC/." /

# Preserve existing FastACL AP assignments/settings on upgrades.
if [ -s "$BACKUP/juliang_fastacl" ]; then
  cp -af "$BACKUP/juliang_fastacl" /etc/config/juliang_fastacl
fi

chmod 0755 \
  /usr/bin/juliang-fastacl \
  /usr/bin/juliang-fastacl-guard \
  /usr/bin/juliang-fastacl-luci-install \
  /usr/bin/uninstall-juliang-fastacl \
  /usr/bin/juliang-operator \
  /etc/init.d/juliang-fastacl \
  /etc/hotplug.d/iface/99-juliang-fastacl \
  /etc/uci-defaults/94-juliang-fastacl-v9 \
  /etc/uci-defaults/97-juliang-operator-mode

sh -n /usr/bin/juliang-fastacl
sh -n /usr/bin/juliang-fastacl-guard
sh -n /usr/bin/juliang-operator
sh -n /etc/uci-defaults/94-juliang-fastacl-v9
sh -n /etc/uci-defaults/97-juliang-operator-mode
lua -e "assert(loadfile('/usr/lib/lua/luci/controller/juliang_fastacl.lua'))"

# Base defaults / Operator mode.
sh /etc/uci-defaults/94-juliang-fastacl-v9
sh /etc/uci-defaults/97-juliang-operator-mode

# 1) Fix FastACL console import HTTP 403 / CSRF path.
echo "[INFO] Applying FastACL console import HTTP 403 fix..."
sh "$IMPORT403_FIX"

# 2) Fix PassWall2 SK5/SOCKS/HTTP shorthand import backend when PassWall2 exists.
if [ -s /usr/share/passwall2/subscribe.lua ]; then
  echo "[INFO] Applying PassWall2 SK5/HTTP import support..."
  sh "$PW2_FIX"
else
  echo "[WARN] PassWall2 subscribe.lua not found; SK5/HTTP backend patch skipped"
fi

# 3) Apply FastACL 2.4 node rename/delete/batch-delete UI + backend.
echo "[INFO] Applying FastACL 2.4 node management UI/backend..."
sh "$V24_UPGRADE"

# Final version stamp must be 2.4.0 even when upgrading from an old config.
uci set juliang_fastacl.main.version='2.4.0'
uci commit juliang_fastacl

rm -f /tmp/luci-indexcache /tmp/luci-indexcache.* 2>/dev/null || true
rm -rf /tmp/luci-modulecache /tmp/luci-templatecache 2>/dev/null || true
/etc/init.d/rpcd restart >/dev/null 2>&1 || true
/etc/init.d/uhttpd restart >/dev/null 2>&1 || true
/etc/init.d/dropbear restart >/dev/null 2>&1 || true

# Re-discover and rebuild only after all UI/backend patches are installed.
echo "[INFO] Discovering wireless topology..."
/usr/bin/juliang-fastacl discover >/tmp/juliang-fastacl24-install-discover.json 2>/tmp/juliang-fastacl24-install-discover.log

echo "[INFO] Building FastACL dataplane and kill-switch..."
if ! /usr/bin/juliang-fastacl repair >/tmp/juliang-fastacl24-install-repair.log 2>&1; then
  echo "[ERROR] FastACL repair failed:" >&2
  cat /tmp/juliang-fastacl24-install-repair.log 2>/dev/null || true
  exit 1
fi
/usr/bin/juliang-fastacl save-state >/dev/null 2>&1 || true

# Core/data-plane checks.
grep -q 'install_killswitch' /usr/bin/juliang-fastacl
grep -q 'move_node(){' /usr/bin/juliang-fastacl
grep -q 'enforce_failclosed_firewall' /usr/bin/juliang-fastacl-guard
nft list table inet juliang_killswitch >/dev/null 2>&1 || { echo "[ERROR] juliang_killswitch missing" >&2; exit 1; }
/usr/bin/juliang-fastacl status | grep -q '^router: running' || {
  echo "[ERROR] FastACL router is not running" >&2
  /usr/bin/juliang-fastacl status || true
  exit 1
}

# Operator checks.
grep -q 'juliang_operator_stats' /usr/lib/lua/luci/controller/juliang_operator.lua
grep -q 'router_down_bytes' /usr/lib/lua/luci/controller/juliang_operator.lua
[ "$(uci -q get juliang_operator.main.username || true)" = "admin" ]
[ "$(uci -q get juliang_operator.main.enabled || true)" = "1" ]

DROP_OK=0
for sec in $(uci -q show dropbear 2>/dev/null | sed -n "s/^dropbear\.\([^.=]*\)=dropbear$/\1/p"); do
  [ "$(uci -q get dropbear.$sec.Port || true)" = "20022" ] && DROP_OK=1
done
[ "$DROP_OK" = "1" ] || { echo "[ERROR] SSH 20022 validation failed" >&2; exit 1; }

# FastACL 2.4 UI/backend checks.
[ "$(uci -q get juliang_fastacl.main.version || true)" = "2.4.0" ] || { echo "[ERROR] FastACL version is not 2.4.0" >&2; exit 1; }
grep -q 'FastACL 2.4 node admin backend fix1' /usr/lib/lua/luci/controller/juliang_fastacl.lua
grep -q 'juliang-fastacl-v24.js?v=2401' /usr/lib/lua/luci/view/juliang_fastacl/console.htm
grep -q 'FastACL 2.4 控制台' /www/luci-static/resources/juliang-fastacl-v24.js
grep -q 'value="重命名"' /www/luci-static/resources/juliang-fastacl-v24.js
grep -q 'value="删除"' /www/luci-static/resources/juliang-fastacl-v24.js
grep -q 'value="删除选中"' /www/luci-static/resources/juliang-fastacl-v24.js

# Import 403 check.
grep -q 'JuLiangTK: FastACL import GET csrf fix' /usr/lib/lua/luci/view/juliang_fastacl/console.htm
grep -q 'XHR.get(IMPORT_API,params' /usr/lib/lua/luci/view/juliang_fastacl/console.htm
if grep -q "x.open('POST',IMPORT_API,true)" /usr/lib/lua/luci/view/juliang_fastacl/console.htm; then
  echo "[ERROR] old HTTP-403-prone POST importer is still present" >&2
  exit 1
fi

# PassWall2 import check when present.
if [ -s /usr/share/passwall2/subscribe.lua ]; then
  lua -e "assert(loadfile('/usr/share/passwall2/subscribe.lua'))"
  grep -q 'JuLiangTK: PassWall2 SK5 HTTP runtime import' /usr/share/passwall2/subscribe.lua
  grep -q 'provider shorthand + sk5 alias' /usr/share/passwall2/subscribe.lua
fi

echo
echo "[OK] JuLiang FastACL 2.4 Stable Full installed"
echo "[OK] FastACL dataplane + Guardian + fail-closed kill-switch"
echo "[OK] FastACL 2.4: rename / single delete / checkbox batch delete"
echo "[OK] FastACL console batch-import HTTP 403 fix"
if [ -s /usr/share/passwall2/subscribe.lua ]; then
  echo "[OK] PassWall2 SK5/SOCKS5/SOCKS/HTTP + host:port:user:pass import support"
fi
echo "[OK] Operator UI enabled"
echo "[OK] SSH port: 20022"
echo "[OK] Operator username: admin"
echo "[OK] Backup: $BACKUP"
echo "[INFO] Root SSH example: ssh -p 20022 root@<router-ip>"

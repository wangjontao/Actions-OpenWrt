#!/bin/sh
set -eu

PIN="2fa09a2695677d9532c0ae1185bf8628b0a92897"
BASE="https://raw.githubusercontent.com/wangjontao/Actions-OpenWrt/$PIN/profiles/fastacl-v9/root"
CTRL="/usr/lib/lua/luci/controller/juliang_operator.lua"
VIEW="/usr/lib/lua/luci/view/juliang_operator/wireless.htm"
BACKUP="/etc/juliang-fastacl/operator-wireless-backup-$(date +%Y%m%d-%H%M%S)"
TMP="/tmp/jfa240-wireless-$$"

cleanup() {
  rm -rf "$TMP" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

fetch() {
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
echo " JuLiang FastACL 2.4.0 Wireless Visibility Update"
echo " Existing system runtime update / NO firmware flash"
echo "=================================================="

mkdir -p "$TMP" "$BACKUP"
[ -f "$CTRL" ] && cp -af "$CTRL" "$BACKUP/"
[ -f "$VIEW" ] && cp -af "$VIEW" "$BACKUP/"

echo "[INFO] Downloading Operator wireless 2.4.0 files..."
fetch "$BASE/usr/lib/lua/luci/controller/juliang_operator.lua" "$TMP/juliang_operator.lua"
fetch "$BASE/usr/lib/lua/luci/view/juliang_operator/wireless.htm" "$TMP/wireless.htm"

grep -q 'action == "visibility"' "$TMP/juliang_operator.lua"
grep -q 'action == "visibility_all"' "$TMP/juliang_operator.lua"
grep -q 'hidden = tostring(s.hidden or "0") == "1"' "$TMP/juliang_operator.lua"
grep -q '一键隐藏全部' "$TMP/wireless.htm"
grep -q 'toggleVisibility' "$TMP/wireless.htm"
grep -q 'toggleAllVisibility' "$TMP/wireless.htm"

if command -v lua >/dev/null 2>&1; then
  lua -e 'assert(loadfile(arg[1]))' "$TMP/juliang_operator.lua"
fi

install -m 0644 "$TMP/juliang_operator.lua" "$CTRL"
install -m 0644 "$TMP/wireless.htm" "$VIEW"

touch /etc/config/juliang_fastacl
uci -q get juliang_fastacl.main >/dev/null 2>&1 || uci set juliang_fastacl.main='main'
uci set juliang_fastacl.main.version='2.4.0'
uci commit juliang_fastacl

rm -f /tmp/luci-indexcache /tmp/luci-indexcache.* 2>/dev/null || true
rm -rf /tmp/luci-modulecache /tmp/luci-templatecache 2>/dev/null || true
/etc/init.d/rpcd restart >/dev/null 2>&1 || true
/etc/init.d/uhttpd restart >/dev/null 2>&1 || true

echo
echo "[OK] FastACL Operator wireless UI updated to 2.4.0"
echo "[OK] Per-SSID: 隐藏无线 / 显示无线"
echo "[OK] Global: 一键隐藏全部 / 一键显示全部"
echo "[OK] Uses wireless.<iface>.hidden=1/0; Wi-Fi itself stays enabled"
echo "[OK] FastACL/DHCP/network config unchanged"
echo "[INFO] Backup: $BACKUP"

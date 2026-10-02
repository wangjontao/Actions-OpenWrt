#!/bin/sh
set -eu

PIN="71fc5a8f35d724bc0a78be5e16d1e16a592b1572"
URL="https://raw.githubusercontent.com/wangjontao/Actions-OpenWrt/$PIN/profiles/fastacl-v9/root/usr/lib/lua/luci/view/juliang_operator/home.htm"
DST="/usr/lib/lua/luci/view/juliang_operator/home.htm"
TMP="/tmp/jfa-op-home-fix3-$$"

echo "=================================================="
echo " JuLiang Operator 2.3.7 Fix3"
echo " repair operator-home runtime error"
echo "=================================================="

curl -4 -fL --connect-timeout 8 --max-time 60 --retry 2 -o "$TMP" "$URL"
[ -s "$TMP" ]

grep -q 'local out = sys.exec' "$TMP"
grep -q 'return out' "$TMP"

mkdir -p /etc/juliang-fastacl /usr/lib/lua/luci/view/juliang_operator
cp -af "$DST" /etc/juliang-fastacl/operator-home.pre-237-fix3 2>/dev/null || true
cp -af "$TMP" "$DST"
chmod 0644 "$DST"
rm -f "$TMP"

rm -f /tmp/luci-indexcache /tmp/luci-indexcache.* 2>/dev/null || true
rm -rf /tmp/luci-modulecache /tmp/luci-templatecache 2>/dev/null || true
/etc/init.d/uhttpd restart >/dev/null 2>&1 || true

echo "[OK] operator homepage runtime bug repaired"
echo "[INFO] open a private/incognito window and log in with the operator account again"

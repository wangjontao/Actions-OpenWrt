#!/bin/sh
set -eu

PIN="c5deaebcf4045735c35992beec947e1fb53e9066"
URL="https://raw.githubusercontent.com/wangjontao/Actions-OpenWrt/$PIN/profiles/fastacl-v9/root/usr/lib/lua/luci/view/juliang_operator/home.htm"
DST="/usr/lib/lua/luci/view/juliang_operator/home.htm"
TMP="/tmp/jfa-op-home-fix1-$$"

echo "=================================================="
echo " JuLiang Operator 2.3.7 Fix1"
echo " repair custom-home template syntax"
echo "=================================================="

curl -4 -fL --connect-timeout 8 --max-time 60 --retry 2 -o "$TMP" "$URL"
[ -s "$TMP" ]
grep -q 'jsonfilter -e' "$TMP"
grep -q '\[=\[' "$TMP"

mkdir -p /usr/lib/lua/luci/view/juliang_operator
cp -af "$DST" /etc/juliang-fastacl/home.htm.pre-237-fix1 2>/dev/null || true
cp -af "$TMP" "$DST"
chmod 0644 "$DST"
rm -f "$TMP"

rm -f /tmp/luci-indexcache /tmp/luci-indexcache.* 2>/dev/null || true
rm -rf /tmp/luci-modulecache /tmp/luci-templatecache 2>/dev/null || true
/etc/init.d/uhttpd restart >/dev/null 2>&1 || true

echo "[OK] custom-home template syntax repaired"
echo "[INFO] refresh /cgi-bin/luci/ or reopen an incognito window"

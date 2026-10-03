#!/bin/sh
set -eu

PIN="0dc54891eb78d2b9bc8835453fa718939394aa76"
ARCHIVE="https://codeload.github.com/wangjontao/Actions-OpenWrt/tar.gz/$PIN"
TMP="/tmp/fastc010-$$"
TGZ="$TMP/fastc.tar.gz"

cleanup(){ rm -rf "$TMP" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

fetch(){
  if command -v curl >/dev/null 2>&1; then
    curl -4 -fL --connect-timeout 8 --max-time 240 --retry 3 -o "$TGZ" "$ARCHIVE"
  elif command -v wget >/dev/null 2>&1; then
    wget -O "$TGZ" "$ARCHIVE"
  else
    echo "[ERROR] curl/wget not found" >&2
    exit 1
  fi
}

echo "=================================================="
echo " FastC 0.1.0-dev Installer"
echo " mihomo-based FastACL successor prototype"
echo "=================================================="

mkdir -p "$TMP"
fetch
mkdir -p "$TMP/src"
tar -xzf "$TGZ" --strip-components=1 -C "$TMP/src"
SRC="$TMP/src/profiles/fastc-v010/root"
[ -d "$SRC" ] || { echo "[ERROR] FastC profile not found" >&2; exit 1; }

mkdir -p /etc/fastc
[ -f /etc/fastc/nodes.json ] || echo '[]' > /etc/fastc/nodes.json
cp -af "$SRC/." /
chmod 0755 /usr/libexec/fastc-import.lua

rm -f /tmp/luci-indexcache /tmp/luci-indexcache.* 2>/dev/null || true
rm -rf /tmp/luci-modulecache /tmp/luci-templatecache 2>/dev/null || true
/etc/init.d/rpcd restart >/dev/null 2>&1 || true
/etc/init.d/uhttpd restart >/dev/null 2>&1 || true

echo
if command -v mihomo >/dev/null 2>&1; then
  echo "[OK] mihomo detected: $(mihomo -v 2>/dev/null | head -n1 || true)"
elif command -v clash >/dev/null 2>&1; then
  echo "[OK] clash-compatible core detected: $(clash -v 2>/dev/null | head -n1 || true)"
else
  echo "[WARN] mihomo core not detected yet; UI/import can still be tested"
fi

echo "[OK] FastC 0.1.0-dev UI installed"
echo "[OK] Node database: /etc/fastc/nodes.json"
echo "[OK] Importer: /usr/libexec/fastc-import.lua"
echo "[INFO] LuCI: Services -> FastC"
echo "[INFO] This development build imports nodes but does not yet take over traffic."

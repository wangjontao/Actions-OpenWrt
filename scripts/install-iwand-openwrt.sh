#!/bin/sh
set -eu

ROOT="${1:-.}"
IWAND_REPO="${IWAND_REPO:-https://github.com/Ricky-Hao/iwand.git}"
IWAND_REF="${IWAND_REF:-v0.2.0}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM

printf '%s\n' "[iWAN] integrating ${IWAND_REPO}@${IWAND_REF} into ${ROOT}"

git clone --depth=1 --branch "$IWAND_REF" "$IWAND_REPO" "$TMP/iwand"

rm -rf "$ROOT/package/iwand" "$ROOT/package/luci-app-iwand"
cp -a "$TMP/iwand/openwrt/package" "$ROOT/package/iwand"
cp -a "$TMP/iwand/luci-app-iwand" "$ROOT/package/luci-app-iwand"

# JuLiang/OpenWrt UI naming only; protocol implementation remains upstream iwand.
MENU="$ROOT/package/luci-app-iwand/root/usr/share/luci/menu.d/luci-app-iwand.json"
VIEW="$ROOT/package/luci-app-iwand/htdocs/luci-static/resources/view/iwand.js"
[ -f "$MENU" ] && sed -i 's/"title": "iWAN SD-WAN"/"title": "派网 iWAN"/' "$MENU"
[ -f "$VIEW" ] && sed -i "s/_('iWAN SD-WAN')/_('派网 iWAN')/" "$VIEW"

# Sanity checks: client package, LuCI package, procd init and UCI config must all exist.
test -s "$ROOT/package/iwand/Makefile"
test -s "$ROOT/package/luci-app-iwand/Makefile"
test -s "$ROOT/package/luci-app-iwand/root/etc/init.d/iwand"
test -s "$ROOT/package/luci-app-iwand/root/etc/config/iwand"
test -s "$ROOT/package/luci-app-iwand/htdocs/luci-static/resources/view/iwand.js"

grep -q 'DEPENDS:=+kmod-tun' "$ROOT/package/iwand/Makefile"
grep -q 'LUCI_DEPENDS:=+iwand' "$ROOT/package/luci-app-iwand/Makefile"

printf '%s\n' "[iWAN] integration ready: package/iwand + package/luci-app-iwand"

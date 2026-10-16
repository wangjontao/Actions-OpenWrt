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

# Keep service/config ownership in the daemon package. The upstream LuCI init
# understands UCI; the daemon upstream init only reads a static INI file.
cp "$TMP/iwand/luci-app-iwand/root/etc/init.d/iwand" "$ROOT/package/iwand/files-init"
mkdir -p "$ROOT/package/iwand/files"
mv "$ROOT/package/iwand/files-init" "$ROOT/package/iwand/files/iwand.init"
cp "$TMP/iwand/luci-app-iwand/root/etc/config/iwand" "$ROOT/package/iwand/files/iwand.config"
rm "$ROOT/package/luci-app-iwand/root/etc/init.d/iwand"
rm "$ROOT/package/luci-app-iwand/root/etc/config/iwand"
# Bundle the exact checked-out client sources instead of fetching the stale
# v0.1.0 reference embedded in the upstream v0.2.0 OpenWrt recipe.
cp -a "$TMP/iwand/src" "$ROOT/package/iwand/src"
"${PYTHON:-python3}" - "$ROOT/package/iwand/Makefile" <<'PY'
import pathlib, re, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text()
s = re.sub(r'^PKG_VERSION:=.*$', 'PKG_VERSION:=0.2.0', s, flags=re.M)
s = re.sub(r'^PKG_SOURCE_(?:PROTO|URL|DATE|VERSION):=.*\n', '', s, flags=re.M)
s = re.sub(r'^PKG_MIRROR_HASH:=.*\n', '', s, flags=re.M)
s = s.replace('/etc/sdwan/iwan.conf', '/etc/config/iwand')
s = s.replace('define Build/Compile', 'define Build/Prepare\n\t$(INSTALL_DIR) $(PKG_BUILD_DIR)/src\n\t$(CP) ./src/. $(PKG_BUILD_DIR)/src/\nendef\n\ndefine Build/Compile')
a = s.index('\t$(INSTALL_DIR) $(1)/etc/init.d', s.index('define Package/iwand/install'))
b = s.index('\nendef', a)
s = s[:a] + '\t$(INSTALL_DIR) $(1)/etc/init.d $(1)/etc/config\n\t$(INSTALL_BIN) ./files/iwand.init $(1)/etc/init.d/iwand\n\t$(INSTALL_CONF) ./files/iwand.config $(1)/etc/config/iwand\n' + s[b:]
p.write_text(s)
PY

# JuLiang/OpenWrt UI naming only; protocol implementation remains upstream iwand.
MENU="$ROOT/package/luci-app-iwand/root/usr/share/luci/menu.d/luci-app-iwand.json"
VIEW="$ROOT/package/luci-app-iwand/htdocs/luci-static/resources/view/iwand.js"
[ -f "$MENU" ] && sed -i 's/"title": "iWAN SD-WAN"/"title": "派网 iWAN"/' "$MENU"
[ -f "$VIEW" ] && sed -i "s/_('iWAN SD-WAN')/_('派网 iWAN')/" "$VIEW"

# Sanity checks: client package, LuCI package, procd init and UCI config must all exist.
test -s "$ROOT/package/iwand/Makefile"
test -s "$ROOT/package/luci-app-iwand/Makefile"
test -s "$ROOT/package/iwand/files/iwand.init"
test ! -e "$ROOT/package/luci-app-iwand/root/etc/init.d/iwand"
test -s "$ROOT/package/iwand/files/iwand.config"
test ! -e "$ROOT/package/luci-app-iwand/root/etc/config/iwand"
test -s "$ROOT/package/luci-app-iwand/htdocs/luci-static/resources/view/iwand.js"

grep -q 'DEPENDS:=+kmod-tun' "$ROOT/package/iwand/Makefile"
grep -q 'LUCI_DEPENDS:=+iwand' "$ROOT/package/luci-app-iwand/Makefile"

printf '%s\n' "[iWAN] integration ready: package/iwand + package/luci-app-iwand"

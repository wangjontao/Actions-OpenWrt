#!/bin/sh
set -eu

PIN="2049b19f87b7832d1d40edd7798001024ae91bc2"
ARCHIVE="https://codeload.github.com/wangjontao/Actions-OpenWrt/tar.gz/$PIN"
TMP="/tmp/jfa239-full-$$"
TGZ="/tmp/jfa239-full-$$.tar.gz"
BACKUP="/etc/juliang-fastacl/full-installer-backup-$(date +%Y%m%d-%H%M%S)"

cleanup() {
  rm -rf "$TMP" "$TGZ" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

fetch() {
  if command -v curl >/dev/null 2>&1; then
    curl -4 -fL --connect-timeout 8 --max-time 180 --retry 2 -o "$TGZ" "$ARCHIVE"
  elif command -v wget >/dev/null 2>&1; then
    wget -O "$TGZ" "$ARCHIVE"
  else
    echo "[ERROR] curl/wget not found" >&2
    exit 1
  fi
}

echo "=================================================="
echo " JuLiang FastACL 2.3.9 Stable - Full Installer"
echo " FastACL + Operator UI + SSH 20022"
echo "=================================================="

mkdir -p "$TMP" "$BACKUP"

if ! command -v nft >/dev/null 2>&1; then
  echo "[INFO] nft command missing; installing nftables userspace..."
  command -v opkg >/dev/null 2>&1 || {
    echo "[ERROR] nft is missing and opkg is unavailable" >&2
    exit 1
  }
  opkg update
  opkg install nftables-json >/dev/null 2>&1 || opkg install nftables-nojson
fi
command -v nft >/dev/null 2>&1 || {
  echo "[ERROR] nft installation failed" >&2
  exit 1
}

fetch
[ -s "$TGZ" ] || { echo "[ERROR] download failed"; exit 1; }
tar -xzf "$TGZ" -C "$TMP"

SRC="$(find "$TMP" -type d -path '*/profiles/fastacl-v9/root' | head -n1)"
[ -n "$SRC" ] && [ -d "$SRC" ] || { echo "[ERROR] profile root not found"; exit 1; }

if [ -s /etc/config/juliang_fastacl ]; then
  cp -af /etc/config/juliang_fastacl "$BACKUP/juliang_fastacl"
fi
cp -af /etc/config/dropbear "$BACKUP/dropbear" 2>/dev/null || true
cp -af /etc/config/rpcd "$BACKUP/rpcd" 2>/dev/null || true

cp -af "$SRC/." /

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

sh /etc/uci-defaults/94-juliang-fastacl-v9
sh /etc/uci-defaults/97-juliang-operator-mode

rm -f /tmp/luci-indexcache /tmp/luci-indexcache.* 2>/dev/null || true
rm -rf /tmp/luci-modulecache /tmp/luci-templatecache 2>/dev/null || true
/etc/init.d/rpcd restart >/dev/null 2>&1 || true
/etc/init.d/uhttpd restart >/dev/null 2>&1 || true
/etc/init.d/dropbear restart >/dev/null 2>&1 || true

echo "[INFO] Discovering wireless topology..."
/usr/bin/juliang-fastacl discover >/tmp/juliang-fastacl-install-discover.json 2>/tmp/juliang-fastacl-install-discover.log

echo "[INFO] Building FastACL dataplane and kill-switch..."
if ! /usr/bin/juliang-fastacl repair >/tmp/juliang-fastacl-install-repair.log 2>&1; then
  echo "[ERROR] FastACL repair failed:"
  cat /tmp/juliang-fastacl-install-repair.log 2>/dev/null || true
  exit 1
fi
/usr/bin/juliang-fastacl save-state >/dev/null 2>&1 || true

grep -q 'install_killswitch' /usr/bin/juliang-fastacl
grep -q 'move_node(){' /usr/bin/juliang-fastacl
grep -q 'enforce_failclosed_firewall' /usr/bin/juliang-fastacl-guard
grep -q 'juliang_operator_stats' /usr/lib/lua/luci/controller/juliang_operator.lua
grep -q 'router_down_bytes' /usr/lib/lua/luci/controller/juliang_operator.lua
[ "$(uci -q get juliang_operator.main.username || true)" = "admin" ]
[ "$(uci -q get juliang_operator.main.enabled || true)" = "1" ]

DROP_OK=0
for sec in $(uci -q show dropbear 2>/dev/null | sed -n "s/^dropbear\.\([^.=]*\)=dropbear$/\1/p"); do
  [ "$(uci -q get dropbear.$sec.Port || true)" = "20022" ] && DROP_OK=1
done
[ "$DROP_OK" = "1" ]

nft list table inet juliang_killswitch >/dev/null 2>&1 || {
  echo "[ERROR] juliang_killswitch was not created" >&2
  exit 1
}

if ! /usr/bin/juliang-fastacl status | grep -q '^router: running'; then
  echo "[ERROR] FastACL router is not running" >&2
  /usr/bin/juliang-fastacl status || true
  exit 1
fi

echo
echo "[OK] JuLiang FastACL 2.3.9 Stable installed"
echo "[OK] Operator UI installed and enabled"
echo "[OK] SSH port: 20022"
echo "[OK] Operator username: admin"
echo "[OK] Backup: $BACKUP"
echo "[INFO] Root SSH example: ssh -p 20022 root@<router-ip>"

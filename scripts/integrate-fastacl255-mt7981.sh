#!/bin/sh
set -eu
bundle=${GITHUB_WORKSPACE:?}/profiles/fastacl-v252
test -f target/linux/mediatek/filogic/config-6.6
grep -q 'PKG_VERSION:=7.6.6.1' package/mtk/drivers/mt_wifi/Makefile
mkdir -p profiles/fastacl-v252 package/fastacl252 package/juliangtk-dae
cp -a "$bundle/." profiles/fastacl-v252/
cp "$bundle/package-Makefile" package/fastacl252/Makefile
cp "$bundle/core-Makefile" package/juliangtk-dae/Makefile
cp -a "$bundle/root" package/fastacl252/files
(cd profiles/fastacl-v252/dns && go mod tidy && CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -trimpath -ldflags='-s -w' -o ../../../package/fastacl252/files/usr/bin/fastacl252-dns .)
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -trimpath -ldflags='-s -w' -o package/fastacl252/files/usr/libexec/mtwifi-station-bytes "$bundle/mtwifi/mtwifi-station-bytes.go"
chmod 755 package/fastacl252/files/usr/libexec/mtwifi-station-bytes
# Retain this fork's matched hardware DT and MTWiFi. Remove competing mt76 defaults.
python3 "$GITHUB_WORKSPACE/scripts/configure-fastacl255-mt7981.py"
ROOT_HASH=$(openssl passwd -1 '@password@')
sed -i "s#^root:[^:]*:#root:${ROOT_HASH}:#" package/base-files/files/etc/shadow
sed -i 's/192\.168\.[0-9]*\.[0-9]*/192.168.7.1/g' package/base-files/files/bin/config_generate
sh "$GITHUB_WORKSPACE/scripts/integrate-fastacl252-dependencies.sh"
for dev in $MT7981_DEVICES; do
 grep -qx "CONFIG_TARGET_DEVICE_mediatek_filogic_DEVICE_${dev}=y" .config || { echo "Missing device: $dev" >&2; exit 1; }
done
for pkg in fastacl252 juliangtk-dae kmod-mt_wifi mtwifi-cfg iwinfo ip-bridge luci-app-autoreboot luci-app-nps npc; do
 grep -qx "CONFIG_PACKAGE_${pkg}=y" .config || { echo "Missing package: $pkg" >&2; exit 1; }
done
./scripts/diffconfig.sh > MT7981-FastACL255-final.config
# Preserve the hardware-specific LED and dual-IP first-boot payloads.
install -m755 "$GITHUB_WORKSPACE/profiles/mt7981-z8103ax/91-z8103ax-mtwifi-leds" package/fastacl252/files/etc/uci-defaults/91-z8103ax-mtwifi-leds
install -m755 "$GITHUB_WORKSPACE/profiles/mt7981-v2-common/install-dual-ipv3.sh" package/fastacl252/files/usr/libexec/install-juliang-dual-ip.sh
install -m755 "$GITHUB_WORKSPACE/profiles/mt7981-v2-common/95-juliang-dual-ip" package/fastacl252/files/etc/uci-defaults/95-juliang-dual-ip

# First-boot NPS identity: persistent WAN MAC, never overwrite a provisioned vkey.
install -m755 "$GITHUB_WORKSPACE/profiles/fastacl-v252/nps/99-nps-firstboot-mac" package/fastacl252/files/etc/uci-defaults/99-nps-firstboot-mac
install -d package/fastacl252/files/etc/hotplug.d/iface
install -m755 "$GITHUB_WORKSPACE/profiles/fastacl-v252/nps/99-nps-wan-ifup" package/fastacl252/files/etc/hotplug.d/iface/99-nps-wan-ifup

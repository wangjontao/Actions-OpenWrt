from pathlib import Path
import os,re
root=Path(os.environ['GITHUB_WORKSPACE'])
patch=root/'profiles/mt7981-final-multidevice'
# Apply the same reviewed device additions as the existing MT7981 release.
for source in patch.glob('mt7981b-*.dts'):
 Path('target/linux/mediatek/dts',source.name).write_bytes(source.read_bytes())
p=Path('target/linux/mediatek/image/filogic.mk');text=p.read_text()
custom=(patch/'custom-devices.mk').read_text()
for dev in ['aigo_ags21','newland_nl-wr8103','newland_nl-wr9103']:
 if 'TARGET_DEVICES += '+dev not in text:
  block=re.search(r'^define Device/'+re.escape(dev)+r'\n.*?^TARGET_DEVICES \+= '+re.escape(dev)+r'$',custom,re.M|re.S)
  assert block,dev
  text+='\n'+block[0]+'\n'
for token in ['kmod-mt7915e','kmod-mt7981-firmware','mt7981-wo-firmware']:
 text=text.replace(token,'')
text=text.replace('  PAGESIZE := 2048\n  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata\nendef\nTARGET_DEVICES += jcg_q30-pro','  PAGESIZE := 2048\n  IMAGE_SIZE := 113152k\n  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata\nendef\nTARGET_DEVICES += jcg_q30-pro')
image_definitions=text
p.write_text(text)
p=Path('target/linux/mediatek/filogic/base-files/etc/board.d/02_network');text=(patch/'02_network').read_text()
if 'zbtlink,zbt-z8103ax-c' not in text:
 text=text.replace('case "$board" in\n','case "$board" in\n\tzbtlink,zbt-z8103ax-c*)\n\t\tucidef_set_interfaces_lan_wan "lan1 lan2 lan3" eth1\n\t\t;;\n',1)
p.write_text(text)
# Keep MTWiFi's dependent HNAT module but reserve forwarding for dae/eBPF.
# WHNAT cannot be enabled behind the control plane through the debugfs toggle.
p=Path('target/linux/mediatek/files-6.6/drivers/net/ethernet/mediatek/mtk_hnat/hnat.c')
t=p.read_text();start=t.index('int hnat_enable_hook(void)');end=t.index('int hnat_disable_hook(void)',start)
t=t[:start]+'int hnat_enable_hook(void)\n{\n\t/* FastACL 2.5.6: CPU forwarding is required for dae policy enforcement. */\n\treturn 0;\n}\n\n'+t[end:];p.write_text(t)
# Start from the exact working MT7981 vendor defconfig used by run 39188165805.
# Filtering to CONFIG_MTK_* omitted related wireless/EEPROM selections and
# made MTWiFi 7.6.6.1 fail with undefined calibration constants.
vendor=Path('defconfig/mt7981-ax3000.config').read_text()
vendor_lines=[line for line in vendor.splitlines()
 if not line.startswith('CONFIG_TARGET_DEVICE_mediatek_filogic_DEVICE_')
 and not line.startswith('CONFIG_TARGET_DEVICE_PACKAGES_mediatek_filogic_DEVICE_')]
base='\n'.join(vendor_lines)+'\n'
# Apply FastACL package choices on top, retaining the entire known-good WiFi base.
fastacl=(root/'profiles/fastacl-v252/mt7981-common.config').read_text()
base+=fastacl
base+='CONFIG_TARGET_mediatek=y\nCONFIG_TARGET_mediatek_filogic=y\nCONFIG_TARGET_MULTI_PROFILE=y\nCONFIG_TARGET_PER_DEVICE_ROOTFS=y\n'
base+='CONFIG_PACKAGE_kmod-mt_wifi=y\nCONFIG_PACKAGE_mtwifi-cfg=y\nCONFIG_PACKAGE_luci-app-mtwifi-cfg=y\nCONFIG_PACKAGE_luci-i18n-mtwifi-cfg-zh-cn=y\nCONFIG_PACKAGE_iwinfo=y\nCONFIG_PACKAGE_ip-bridge=y\n'
devices=os.environ['MT7981_DEVICES'].split();assert devices
for dev in devices:
 assert re.fullmatch(r'[a-z0-9_-]+',dev) and 'TARGET_DEVICES += '+dev in image_definitions,dev
 base+='CONFIG_TARGET_DEVICE_mediatek_filogic_DEVICE_'+dev+'=y\n'
Path('.config').write_text(base)

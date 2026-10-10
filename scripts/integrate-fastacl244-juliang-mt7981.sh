#!/bin/sh
set -eu
PROFILE="$GITHUB_WORKSPACE/profiles/fastacl244-juliang-mt7981"
mkdir -p files
cp -a "$PROFILE/root/." files/
for script in files/usr/bin/juliang-fastacl* files/usr/bin/uninstall-juliang-fastacl files/usr/libexec/juliang-fastacl-* files/etc/init.d/juliang-fastacl files/etc/init.d/juliang-domestic-dns files/etc/uci-defaults/96-juliang-fastacl-dns files/etc/hotplug.d/iface/99-juliang-fastacl files/etc/uci-defaults/94-juliang-fastacl-v9; do
    chmod 0755 "$script"
done
for plugin in passwall passwall2; do
    package_dir="package/${plugin}-luci/luci-app-${plugin}"
    test -f "$package_dir/Makefile" || { echo "[ERROR] Missing pinned package: $package_dir"; exit 1; }
    mkdir -p "$package_dir/luasrc/view/$plugin"
    cp "$PROFILE/acl/${plugin}.htm" "$package_dir/luasrc/view/$plugin/acl_ip_refresh.htm"
    echo "[OK] Installed custom $plugin ACL template"
done
importer=$(find package/passwall2-luci -path '*/root/usr/share/passwall2/subscribe.lua' -print -quit)
test -n "$importer" || { echo "[ERROR] PassWall2 importer missing"; exit 1; }
task_dir=$(mktemp -d)
trap 'rm -rf "$task_dir"' EXIT HUP INT TERM
sed "s|^TARGET=/usr/share/passwall2/subscribe.lua$|TARGET=$PWD/$importer|;s|^BASE=/etc/passwall2-import-repair$|BASE=$task_dir/import-backup|" files/usr/bin/juliang-fastacl-import-repair > "$task_dir/import-repair.sh"
sh "$task_dir/import-repair.sh"
for script in files/usr/bin/juliang-fastacl* files/etc/init.d/juliang-fastacl files/etc/uci-defaults/94-juliang-fastacl-v9; do
    sh -n "$script"
done
for source in $(find files/usr/lib/lua files/usr/libexec -name '*.lua'); do
    luac -p "$source"
done
grep -q "option version '2.4.4'" files/etc/config/juliang_fastacl
grep -q 'additional_limit=additional' files/usr/lib/lua/juliang_fastacl_wifi.lua
test ! -e files/etc/uci-defaults/97-juliang-operator-mode
printf '%s\n' '[OK] FastACL 2.4.4: parser, Lua, shell and extra-WiFi limits verified.'

case "${BUILD_VARIANT:-1010V1}" in
1010V1) ;; 
1010V2-10WiFi)
 python3 - <<'PYVAR'
from pathlib import Path
p=Path('files/usr/lib/lua/juliang_fastacl_wifi.lua')
s=p.read_text().replace('band=="5g" and 4 or band=="2g" and 1','band=="5g" and 8 or band=="2g" and 3').replace('0,0,4,"每个频段的新增数量需为 0～4"','0,0,8,"每个频段的新增数量需为 0～8"').replace('total>5','total>11').replace('1～5','1～11')
p.write_text(s)
p=Path('files/usr/lib/lua/luci/view/juliang_fastacl/batch_wifi.htm');s=p.read_text().replace('单次最多新增 5 个，5GHz 最多新增 4 个，2.4GHz 最多新增 1 个','单次最多新增 11 个，5GHz 最多新增 8 个，2.4GHz 最多新增 3 个');p.write_text(s)
PYVAR
 ;; 
*) exit 1;;
esac
luac -p files/usr/lib/lua/juliang_fastacl_wifi.lua
printf '%s\n' "$BUILD_VARIANT" > files/etc/juliang-build-version

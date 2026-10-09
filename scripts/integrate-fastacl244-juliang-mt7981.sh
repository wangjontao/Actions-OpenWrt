#!/bin/sh
set -eu
PROFILE="$GITHUB_WORKSPACE/profiles/fastacl244-juliang-mt7981"
mkdir -p files
cp -a "$PROFILE/root/." files/
for script in files/usr/bin/juliang-fastacl* files/usr/bin/uninstall-juliang-fastacl files/usr/libexec/juliang-fastacl-* files/etc/init.d/juliang-fastacl files/etc/hotplug.d/iface/99-juliang-fastacl files/etc/uci-defaults/94-juliang-fastacl-v9; do
    chmod 0755 "$script"
done
for plugin in passwall passwall2; do
    dest=$(find "package/${plugin}-luci" -path "*/luasrc/view/${plugin}/acl_ip_refresh.htm" -print -quit)
    test -n "$dest"
    cp "$PROFILE/acl/${plugin}.htm" "$dest"
done
importer=$(find package/passwall2-luci -path '*/root/usr/share/passwall2/subscribe.lua' -print -quit)
test -n "$importer"
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

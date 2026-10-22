local u=require('uci').cursor()
local changed=require('fastacl252_wifi').sync_firewall_devices(u)
if changed>0 then
 assert(u:commit('firewall'),'Cannot save managed WiFi firewall bridges')
 assert(os.execute('/etc/init.d/firewall reload >/tmp/fastacl252-wifi-fw4.log 2>&1')==0,'Cannot reload WiFi DHCP/DNS firewall rules')
end
print('Managed WiFi firewall bridge bindings updated: '..changed)

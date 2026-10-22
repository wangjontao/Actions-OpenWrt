from pathlib import Path
import sys
from lupa.lua51 import LuaRuntime
lua=LuaRuntime(unpack_returned_tuples=True);m=lua.execute((Path(__file__).resolve().parents[1]/'root/usr/lib/lua/fastacl252_wifi.lua').read_text())
lua.execute('''local owner='fastacl252-dev2'
configs={fastacl252={jfa25w01={['.name']='jfa25w01',jfa25_owner=owner,network='jfa25w01'},jfa25w02={['.name']='jfa25w02',jfa25_owner=owner,network='jfa25w02'},lan={['.name']='lan',network='lan'}},network={},firewall={lan={name='lan',network={'lan'}}}}
for _,id in ipairs({'jfa25w01','jfa25w02'})do configs.network[id]={jfa25_owner=owner,device='br-'..id};configs.network[id..'_dev']={jfa25_owner=owner,name='br-'..id,type='bridge'};configs.firewall[id]={jfa25_owner=owner,name=id,network={id},device={'existing-device'}}end
configs.firewall.jfa25w02.jfa25_owner='unrelated'
u={foreach=function(self,c,t,cb)for _,v in pairs(configs[c])do cb(v)end end,get_all=function(self,c,n)return configs[c][n]end,set=function(self,c,n,k,v)configs[c][n][k]=v;return true end}
''')
assert m.sync_firewall_devices(lua.globals().u)==1;assert m.sync_firewall_devices(lua.globals().u)==0;assert lua.eval("configs.firewall.jfa25w01.device[1]")=='existing-device';assert lua.eval("configs.firewall.jfa25w01.device[2]")=='br-jfa25w01';assert lua.eval("#configs.firewall.jfa25w02.device")==1;assert lua.eval('configs.firewall.lan.device') is None
s=(Path(__file__).resolve().parents[1]/'root/usr/lib/lua/fastacl252_wifi.lua').read_text();assert 'network={id},device={dev}' in s
print('PASS migration idempotence, existing devices preserved, main/unowned zones unchanged; new WiFi explicitly pins its bridge')

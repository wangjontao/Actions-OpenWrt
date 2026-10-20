local M=require('fastacl252_wifi')
local function fixture()
 local u={data={fastacl252={},wireless={}},writes=0}
 for _,id in ipairs({'jfa25w01','jfa25w02'}) do u.data.fastacl252[id]={['.type']='wifi',network=id,jfa25_owner=M.owner};u.data.wireless[id]={['.type']='wifi-iface',network=id,mode='ap',jfa25_owner=M.owner,hidden='0',disabled='0'} end
 u.data.wireless.lan={['.type']='wifi-iface',network='lan',mode='ap',hidden='0'}
 function u:get_all(cfg,id) return self.data[cfg][id] end
 function u:set(cfg,id,key,v) self.writes=self.writes+1;self.data[cfg][id][key]=v;return true end
 return u
end
local u=fixture();M.hide_one(u,'jfa25w01',true);assert(u.data.wireless.jfa25w01.hidden=='1');assert(u.data.wireless.jfa25w01.disabled=='0');assert(u.data.wireless.jfa25w02.hidden=='0' and u.data.wireless.lan.hidden=='0');M.hide_one(u,'jfa25w01',false);assert(u.data.wireless.jfa25w01.hidden=='0')
for _,id in ipairs({'lan','jfa25w99','../lan'}) do u=fixture();assert(not pcall(M.hide_one,u,id,true));assert(u.writes==0) end
u=fixture();u.data.wireless.jfa25w01.jfa25_owner='other';assert(not pcall(M.hide_one,u,'jfa25w01',true));assert(u.writes==0)
u=fixture();assert(not pcall(M.hide_one,u,'jfa25w01','false'));assert(u.writes==0)
print('PASS: hide/show changes target SSID broadcast only; main/other WiFi preserved; ownership and boolean checks enforced')


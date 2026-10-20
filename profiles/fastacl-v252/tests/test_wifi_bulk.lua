local M=require('fastacl252_wifi')
local function fixture()
 local u={data={},deleted=0}
 for _,cfg in ipairs({'fastacl252','network','wireless','firewall','dhcp'}) do u.data[cfg]={} end
 u.data.fastacl252.main={['.name']='main',['.type']='main',network='lan'}
 for _,cfg in ipairs({'network','wireless','firewall','dhcp'}) do u.data[cfg].lan={['.name']='lan',['.type']='interface',ssid='Main'};u.data[cfg].other={['.name']='other',['.type']='interface'} end
 for _,id in ipairs({'jfa25w01','jfa25w02'}) do
  u.data.fastacl252[id]={['.name']=id,['.type']='wifi',network=id,jfa25_owner=M.owner}
  for _,cfg in ipairs({'network','wireless','firewall','dhcp'}) do u.data[cfg][id]={['.name']=id,['.type']='interface',jfa25_owner=M.owner,jfa25_network=id} end
 end
 function u:get(cfg,id,key) local s=self.data[cfg][id];return s and s[key] end
 function u:get_all(cfg,id) return self.data[cfg][id] end
 function u:foreach(cfg,kind,fn) for _,s in pairs(self.data[cfg]) do if not kind or s['.type']==kind then fn(s) end end end
 function u:delete(cfg,id) self.deleted=self.deleted+1;self.data[cfg][id]=nil end
 return u
end
for _,ids in ipairs({{}, {'jfa25w01','lan'}, {'jfa25w01','jfa25w01'}, {'jfa25w01','jfa25w99'}}) do local u=fixture();assert(not pcall(M.remove_many,u,ids));assert(u.deleted==0,'Invalid batch partially deleted configuration') end
local u=fixture();u.data.fastacl252.jfa25w02.jfa25_owner='other';assert(not pcall(M.remove_many,u,{'jfa25w01','jfa25w02'}));assert(u.deleted==0)
u=fixture();u.data.fastacl252.jfa25w02.network='lan';assert(not pcall(M.remove_all,u,{'jfa25w01','jfa25w02'}));assert(u.deleted==0,'Main network reference deleted')
u=fixture();assert(not pcall(M.remove_all,u,{'jfa25w01'}));assert(u.deleted==0);local result=M.remove_many(u,{'jfa25w01'});assert(result.count==1);assert(u.data.fastacl252.jfa25w02);assert(not u.data.fastacl252.jfa25w01)
u=fixture();result=M.remove_all(u,{'jfa25w01','jfa25w02'});assert(result.count==2);for _,cfg in ipairs({'network','wireless','firewall','dhcp'}) do assert(u.data[cfg].lan and u.data[cfg].other);assert(not u.data[cfg].jfa25w01 and not u.data[cfg].jfa25w02) end
print('PASS: batch/all delete uses owned WiFi only; entire batch validated before mutation; main/unrelated networks preserved')


-- MTWiFi SSID visibility can be updated without unloading the wireless driver.
local M={}
function M.apply(u,id,options)
 options=options or {};local targets={};local native=false
 local wanted
 if type(id)=='table' then wanted={};assert(#id>0 and #id<=128,'无效批量 WiFi');for _,name in ipairs(id)do assert(type(name)=='string' and name:match('^jfa25w%d+$') and not wanted[name],'无效附加 WiFi');wanted[name]=true end
 elseif id~='all' then assert(type(id)=='string' and id:match('^jfa25w%d+$'),'无效附加 WiFi') end
 local found={}
 u:foreach('wireless','wifi-iface',function(w)
  if (id=='all' or (wanted and wanted[w['.name']]) or w['.name']==id) and (not w.mode or w.mode=='ap') then
   found[w['.name']]=true
   local driver=u:get('wireless',w.device,'type')
   if driver~='mtwifi' then native=true else targets[#targets+1]={section=w['.name'],device=w.device,hidden=w.hidden=='1' and 1 or 0} end
  end
 end)
 if wanted then for name in pairs(wanted)do assert(found[name],'无线接口不存在')end end
 assert(id=='all' or #targets>0 or native,'无线接口不存在')
 local call=options.call or require('luci.sys').call
 if native then assert(call('wifi reload >/dev/null 2>&1')==0,'WiFi reload 失败');return {path='wireless-reload'} end
 local status=options.status or require('luci.jsonc').parse(require('luci.sys').exec('ubus -t 5 call network.wireless status'))
 assert(type(status)=='table','读取无线接口失败')
 local mapping={}
 for device,r in pairs(status) do for _,iface in ipairs(r.interfaces or {}) do
  if iface.section then assert(not mapping[iface.section],'无线接口映射重复');mapping[iface.section]={name=iface.ifname,device=device} end
 end end
 -- Verify all targets before issuing any driver command.
 for _,t in ipairs(targets) do
  local m=mapping[t.section];assert(m and m.device==t.device and type(m.name)=='string' and m.name:match('^ra[x]?%d+$'),'无线接口尚未就绪，请稍后再试')
  t.ifname=m.name
 end
 for _,t in ipairs(targets) do assert(call('iwpriv '..t.ifname..' set HideSSID='..t.hidden..' >/dev/null 2>&1')==0,'更新 SSID 广播失败') end
 return {path='mtwifi-runtime',count=#targets}
end
return M

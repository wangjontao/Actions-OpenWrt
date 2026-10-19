-- Hide unneeded menu trees without changing the underlying NAS services.
local fs=require'nixio.fs';local json=require'luci.jsonc'
for name in fs.dir('/usr/share/luci/menu.d') do
 if name:match('%.json$') then
  local path='/usr/share/luci/menu.d/'..name;local obj=json.parse(fs.readfile(path) or '');local changed=false
  if type(obj)=='table' then
   for k in pairs(obj) do if k=='admin/nas' or k:match('^admin/nas/') or k=='admin/statistics' or k:match('^admin/statistics/') then obj[k]=nil;changed=true end end
   if obj['admin/services'] then obj['admin/services'].title=nil;changed=true end
   for _,key in ipairs({'admin/services/ddns','admin/services/wol','admin/services/ksmbd'}) do
    if obj[key] then obj[key].title=nil;changed=true end
   end
   if obj['admin/services/upnp'] then
    obj['admin/network/upnp']=obj['admin/services/upnp'];obj['admin/services/upnp']=nil
    obj['admin/network/upnp'].order=75;changed=true
   end
   if changed then fs.writefile(path,next(obj) and json.stringify(obj) or '{}');fs.chmod(path,'644') end
  end
 end
end
-- Preserve the installed NPS package/service, changing only its LuCI routes.
local nps='/usr/lib/lua/luci/controller/nps.lua'
if fs.access(nps) then
 local controller=assert(fs.readfile('/usr/libexec/juliang-nps-controller.lua'),'Missing NPS menu payload')
 assert(fs.writefile(nps,controller),'Cannot relocate NPS menu');fs.chmod(nps,'644')
end
fs.remove('/tmp/luci-indexcache')

-- LuCI caches menus per login in sessionStorage, independently of server caches.
-- Invalidate only that menu once when this UI revision is first loaded.
local marker='juliang-menu-revision'
local script=[=[<script id="juliang-menu-revision">(function(){try{var k='luci-session-store',d=JSON.parse(sessionStorage.getItem(k)||'{}'),r='255-device-subscription-list-1';for(var s in d){if(d[s]&&typeof d[s]==='object'&&d[s].juliangMenuRevision!==r){delete d[s].menu;d[s].juliangMenuRevision=r}}sessionStorage.setItem(k,JSON.stringify(d))}catch(e){}})();</script>]=]
for _,path in ipairs({'/usr/share/ucode/luci/template/themes/argon/header.ut','/usr/lib/lua/luci/view/themes/argon/header.htm'}) do
 local text=fs.readfile(path)
 if text then
  text=text:gsub('JuLtiang','JuLiang')
  -- Keep the brand on two deliberate lines at every sidebar width.
  text=text:gsub('>JuLiang%s*控制中心</a>', '><span style="display:block;white-space:nowrap;line-height:1.2;text-align:center">JuLiang</span><span style="display:block;white-space:nowrap;line-height:1.4;text-align:center">控制中心</span></a>')
  text=text:gsub('<script id="juliang%-menu%-revision">.-</script>','')
  local updated,n=text:gsub('<head>',function() return '<head>\n'..script end,1)
  if n>0 then assert(fs.writefile(path,updated));fs.chmod(path,'644') end
 end
end
for path in fs.glob('/tmp/luci-indexcache*') do fs.remove(path) end

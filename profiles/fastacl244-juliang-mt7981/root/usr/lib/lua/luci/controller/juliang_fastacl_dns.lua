module('luci.controller.juliang_fastacl_dns',package.seeall)
function index()
 local s=entry({'admin','services','juliang_fastacl_dns'},call('status'),nil);s.leaf=true;s.acl_depends={'juliang-fastacl-operator'}
 local a=entry({'admin','services','juliang_fastacl_dns_save'},post('save'),nil);a.leaf=true;a.acl_depends={'juliang-fastacl-operator'}
end
local function reply(t) local h=require 'luci.http';h.prepare_content('application/json');h.write(require('luci.jsonc').stringify(t)) end
function status()
 local h=require 'luci.http';local node=h.formvalue('node')
 if node then
  local u=require('luci.model.uci').cursor()
  if u:get('passwall2',node)~='nodes' then reply({ok=false,error='节点不存在'});return end
  reply({ok=true,providers=require('juliang_fastacl_dns').providers,provider=u:get('passwall2',node,'jfa_dns_provider') or 'inherit',route=u:get('passwall2',node,'jfa_dns_route') or 'proxy',url=u:get('passwall2',node,'jfa_dns_url') or '',ip=u:get('passwall2',node,'jfa_dns_ip') or ''});return
 end
 local u=require('luci.model.uci').cursor();local t={ok=true,providers=require('juliang_fastacl_dns').providers,policy=u:get('juliang_fastacl','main','dns_policy') or 'direct'}
 for _,s in ipairs({'domestic','proxy'}) do for _,k in ipairs({'provider','url','ip'}) do t[s..'_'..k]=u:get('juliang_fastacl','main',s..'_dns_'..k) or (k=='provider' and (s=='domestic' and 'alidns' or 'cloudflare') or '') end end
 reply(t)
end
local function save_node()
 local h=require 'luci.http';local u=require('luci.model.uci').cursor();local fs=require 'nixio.fs';local sys=require 'luci.sys'
 local ok,err=pcall(function()
  local node=h.formvalue('node');assert(u:get('passwall2',node)=='nodes','节点不存在')
  local provider=h.formvalue('provider');local route=h.formvalue('route');local url=h.formvalue('url') or '';local ip=h.formvalue('ip') or ''
  assert(route=='direct' or route=='proxy','DNS 路由无效')
  if provider~='inherit' then require('juliang_fastacl_dns').resolve(provider,url,ip) end
  assert(not next(u:changes('passwall2') or {}),'请先处理节点未保存的配置')
  local before=assert(fs.readfile('/etc/config/passwall2'))
  u:set('passwall2',node,'jfa_dns_provider',provider);u:set('passwall2',node,'jfa_dns_route',route);u:set('passwall2',node,'jfa_dns_url',url);u:set('passwall2',node,'jfa_dns_ip',ip);assert(u:commit('passwall2'))
  local code=sys.call('lua /usr/libexec/juliang-fastacl-router.lua > /tmp/jfa-node-dns-preview.json && sing-box check -c /tmp/jfa-node-dns-preview.json >/tmp/jfa-node-dns-check.log 2>&1')
  if code==0 and u:get('juliang_fastacl','main','enabled')=='1' and u:get('juliang_fastacl','main','runtime_mode')~='normal_proxy' then code=sys.call('/usr/bin/juliang-fastacl router-reload >/tmp/jfa-node-dns-apply.log 2>&1') end
  if code~=0 then fs.writefile('/etc/config/passwall2',before);sys.call('/usr/bin/juliang-fastacl router-reload >/dev/null 2>&1');error('节点 DNS 应用失败，已恢复原配置') end
 end)
 reply({ok=ok,error=not ok and tostring(err) or nil})
end
function save()
 if require('luci.http').formvalue('node') then save_node();return end
 local h=require 'luci.http';local u=require('luci.model.uci').cursor();local sys=require 'luci.sys';local fs=require 'nixio.fs'
 local ok,err=pcall(function()
  local policy=h.formvalue('policy');assert(policy=='direct' or policy=='private','DNS 模式无效')
  local values={dns_policy=policy,dns_providers_enabled='1'}
  for _,s in ipairs({'domestic','proxy'}) do
   local id,url,ip=h.formvalue(s..'_provider'),h.formvalue(s..'_url') or '',h.formvalue(s..'_ip') or ''
   require('juliang_fastacl_dns').resolve(id,url,ip)
   values[s..'_dns_provider']=id;values[s..'_dns_url']=url;values[s..'_dns_ip']=ip
  end
  assert(not next(u:changes('juliang_fastacl') or {}) and not next(u:changes('dhcp') or {}),'存在未保存配置，请先保存或撤销')
  local before=assert(fs.readfile('/etc/config/juliang_fastacl'));local dhcp=assert(fs.readfile('/etc/config/dhcp'))
  for k,v in pairs(values) do u:set('juliang_fastacl','main',k,v) end;assert(u:commit('juliang_fastacl'))
  local applied,reason=pcall(function()
   assert(sys.call('lua /usr/libexec/juliang-fastacl-domestic-dns.lua > /tmp/jfa-dns-preview.json && sing-box check -c /tmp/jfa-dns-preview.json >/tmp/jfa-dns-check.log 2>&1')==0,'国内 DNS 配置检查失败')
   assert(sys.call('lua /usr/libexec/juliang-fastacl-router.lua > /tmp/jfa-router-preview.json && sing-box check -c /tmp/jfa-router-preview.json >>/tmp/jfa-dns-check.log 2>&1')==0,'代理 DNS 配置检查失败')
   assert(sys.call('/etc/init.d/juliang-domestic-dns restart')==0,'国内 DNS 启动失败')
   u:set('dhcp','@dnsmasq[0]','noresolv','1');u:set_list('dhcp','@dnsmasq[0]','server',{'127.0.0.1#5354'});assert(u:commit('dhcp'))
   assert(sys.call('/etc/init.d/dnsmasq restart')==0,'DNS 转发启动失败')
   if u:get('juliang_fastacl','main','runtime_mode')~='normal_proxy' and u:get('juliang_fastacl','main','enabled')=='1' then assert(sys.call('/usr/bin/juliang-fastacl router-reload >/tmp/jfa-dns-apply.log 2>&1')==0,'代理核心重载失败') end
   sys.call('/etc/init.d/juliang-domestic-dns enable')
  end)
  if not applied then
   fs.writefile('/etc/config/juliang_fastacl',before);fs.writefile('/etc/config/dhcp',dhcp)
   sys.call('/etc/init.d/juliang-domestic-dns restart; /etc/init.d/dnsmasq restart; /usr/bin/juliang-fastacl router-reload >/dev/null 2>&1')
   error(tostring(reason)..'；已恢复原配置')
  end
 end)
 reply({ok=ok,error=not ok and tostring(err) or nil})
end

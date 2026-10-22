local M={}
local OWNER='fastacl252-dev2'
local CONFIGS={'wireless','network','dhcp','firewall','fastacl252'}

local function fail(s) error(s,0) end
local function int(v,lo,hi,msg)
  local n=tonumber(v)
  if not n or n~=math.floor(n) or n<lo or n>hi then fail(msg) end
  return n
end
local function band_of(s)
  local b=tostring(s.band or '')
  if b=='2g' or b=='2.4g' then return '2g' end
  if b=='5g' then return '5g' end
  local h=tostring(s.hwmode or '')
  if h=='11g' then return '2g' end
  if h=='11a' then return '5g' end
  return ''
end
local function owned(s) return s and s.jfa25_owner==OWNER end
local function next_name(u)
  for i=1,99 do
    local id=string.format('jfa25w%02d',i)
    if not u:get('network',id) and not u:get('wireless',id) and not u:get('fastacl252',id) then return id end
  end
  fail('FastACL 多 WiFi 配置名称已用尽')
end
local function used_subnets(u)
  local used={}; local policy=require 'fastacl252'
  local pool=assert(policy.ipnum('172.16.0.0'))
  local function reserve(address,mask)
    local ip,prefix=tostring(address or ''):match('^([^/]+)/(%d+)$')
    ip=ip or address
    local n=policy.ipnum(ip); local p=tonumber(prefix) or tonumber(mask) or policy.prefix(mask or '255.255.255.0')
    if not n or not p or p<1 or p>32 or p%1~=0 then return end
    local size=2^(32-p); local first=math.floor(n/size)*size; local last=first+size-1
    for i=1,254 do
      local subnet=pool+i*256
      if subnet<=last and subnet+255>=first then used[i]=true end
    end
  end
  u:foreach('network','interface',function(s)
    local addresses=type(s.ipaddr)=='table' and s.ipaddr or {s.ipaddr}
    for _,address in ipairs(addresses) do reserve(address,s.netmask) end
  end)
  -- Include DHCP/WAN and other live routes that have no static UCI address.
  local routes=require('luci.sys').exec('ip -4 route show 2>/dev/null')
  for line in routes:gmatch('[^\n]+') do
    local destination=line:match('^(%d+%.%d+%.%d+%.%d+/?%d*)%s')
    if destination then reserve(destination,'32') end
  end
  return used
end
local function next_subnet(used)
  for n=1,254 do if not used[n] then used[n]=true; return n end end
  fail('172.16.x.0/24 地址池已用尽')
end
local function radio_map(u)
  local r={['2g']={},['5g']={}}
  u:foreach('wireless','wifi-device',function(s)
    local b=band_of(s); if r[b] then r[b][#r[b]+1]=s['.name'] end
  end)
  table.sort(r['2g']); table.sort(r['5g']); return r
end
local function counts(u)
  local c={['2g']=0,['5g']=0}
  u:foreach('fastacl252','wifi',function(s) if owned(s) and c[s.band] then c[s.band]=c[s.band]+1 end end)
  return c
end
local function add(u,cfg,kind,name,values,network)
  values.jfa25_owner=OWNER; values.jfa25_network=network
  assert(not u:get(cfg,name),'配置名称冲突: '..name)
  assert(require('fastacl252').section(u,cfg,kind,name,values),'创建配置失败: '..cfg..'.'..name)
end
local function validate_binding(u,node,pre)
  node=tostring(node or ''); pre=tostring(pre or '')
  if node=='' then return 'direct','','' end
  assert(u:get('fastacl252',node)=='node','请选择有效代理节点')
  if pre~='' then
    assert(pre~=node and u:get('fastacl252',pre)=='node','请选择有效前置节点')
    local p=u:get('fastacl252',node,'protocol')
    assert(p=='socks' or p=='http','只有 SOCKS5 / HTTP 落地节点支持前置代理')
  end
  return 'proxy',node,pre
end
local function set_dns(u,section,req,mode)
  local dns=require 'fastacl252_dns'; local id=tostring(req.dns or 'inherit')
  assert(dns.valid_id(id),'DNS 选择无效')
  if id~='inherit' and id~='custom' then
    local p=assert(dns.provider(id),'DNS 服务商不存在')
    assert(dns.allowed(id,mode),'当前出口不支持此 DNS；代理出口请选择 DoH')
  end
  local tmp={dns=id,dns_type=req.dns_type,dns_ip=req.dns_ip,dns_name=req.dns_name}
  local main=u:get_all('fastacl252','main') or {}; dns.resolve(tmp,mode,main,{},'wifi')
  u:set('fastacl252',section,'dns',id)
  if id=='custom' then
    u:set('fastacl252',section,'dns_type',tmp.dns_type or 'doh'); u:set('fastacl252',section,'dns_ip',tmp.dns_ip or ''); u:set('fastacl252',section,'dns_name',tmp.dns_name or '')
  else
    u:delete('fastacl252',section,'dns_type'); u:delete('fastacl252',section,'dns_ip'); u:delete('fastacl252',section,'dns_name')
  end
end

function M.status(u)
  local main=u:get_all('fastacl252','main') or {}; local map=radio_map(u); local c=counts(u); local rows={}
  u:foreach('fastacl252','wifi',function(s)
    if owned(s) then rows[#rows+1]={id=s['.name'],network=s.network or '',ssid=s.ssid or '',hidden=u:get('wireless',s['.name'],'hidden')=='1',band=s.band or '',subnet=s.subnet or '',mode=s.mode or 'direct',node=s.node or '',preproxy=s.preproxy or '',platforms=s.platforms or '',dns_split=s.dns_split or '0',block_domains=s.block_domains or '',split_mode=s.split_mode or 'all',split_rules=s.split_rules or '',dns=s.dns or 'inherit',dns_type=s.dns_type or '',dns_ip=s.dns_ip or '',dns_name=s.dns_name or ''} end
  end)
  table.sort(rows,function(a,b) return a.id<b.id end)
  return {radios=map,managed=rows,counts=c,max5=tonumber(main.max_wifi_5g or 14),max2=tonumber(main.max_wifi_2g or 8)}
end

function M.create(u,req)
  req=req or {}; local st=M.status(u)
  local n5=int(req.count5 or 0,0,st.max5,'5GHz 新增数量超限'); local n2=int(req.count2 or 0,0,st.max2,'2.4GHz 新增数量超限')
  assert(n5+n2>0,'请至少新增一个 WiFi')
  assert(st.counts['5g']+n5<=st.max5,'5GHz 最多新增 '..st.max5..' 个 WiFi')
  assert(st.counts['2g']+n2<=st.max2,'2.4GHz 最多新增 '..st.max2..' 个 WiFi')
  if n5>0 then assert(#st.radios['5g']>0,'未检测到 5GHz 无线设备') end
  if n2>0 then assert(#st.radios['2g']>0,'未检测到 2.4GHz 无线设备') end
  local key=tostring(req.key or ''); assert(#key>=8 and #key<=63 and not key:find('[^ -~]'),'WiFi 密码需要 8-63 个 ASCII 字符')
  local prefix=tostring(req.prefix or 'A'); assert(#prefix>0 and #prefix<=24 and not prefix:find('[%c]'),'WiFi 名称前缀无效')
  local start=int(req.start or 1,1,999,'WiFi 起始编号无效'); local mode,node,pre=validate_binding(u,req.node,req.preproxy)
  local hidden=req.hidden==true or tostring(req.hidden)=='1'; local used=used_subnets(u); local created={}; local seq=0
  local function one(band,radio)
    local id=next_name(u); local sn=next_subnet(used); seq=seq+1
    local ssid=prefix..tostring(start+seq-1); assert(#ssid<=32,'SSID 超过 32 字节')
    local ip='172.16.'..sn..'.1'; local cidr='172.16.'..sn..'.0/24'; local dev='br-'..id
    add(u,'network','device',id..'_dev',{name=dev,type='bridge',bridge_empty='1',ipv6='0'},id)
    add(u,'network','interface',id,{device=dev,proto='static',ipaddr=ip,netmask='255.255.255.0',delegate='0'},id)
    add(u,'dhcp','dhcp',id,{interface=id,start='100',limit='120',leasetime='12h',ra='disabled',dhcpv6='disabled',ndp='disabled',dhcp_option={'6,'..ip}},id)
    add(u,'wireless','wifi-iface',id,{device=radio,network=id,mode='ap',ssid=ssid,encryption='psk2+ccmp',key=key,isolate='1',disabled='0',hidden=hidden and '1' or '0'},id)
    add(u,'firewall','zone',id,{name=id,network={id},device={dev},input='REJECT',output='ACCEPT',forward='REJECT'},id)
    add(u,'firewall','rule',id..'_dhcp',{name='FastACL '..id..' DHCP',src=id,proto='udp',dest_port='67',family='ipv4',target='ACCEPT'},id)
    add(u,'firewall','rule',id..'_dns',{name='FastACL '..id..' DNS',src=id,proto='tcp udp',dest_port='53 12553',family='ipv4',target='ACCEPT'},id)
    add(u,'firewall','forwarding',id..'_wan',{src=id,dest='wan'},id)
    add(u,'fastacl252','wifi',id,{network=id,ssid=ssid,band=band,subnet=cidr,mode=mode,node=node,preproxy=pre},id)
    set_dns(u,id,req,mode); created[#created+1]={id=id,ssid=ssid,band=band,network=id,subnet=cidr}
  end
  for _=1,n5 do one('5g',st.radios['5g'][1]) end
  for _=1,n2 do one('2g',st.radios['2g'][1]) end
  return created
end

function M.update(u,req)
  local id=tostring(req.id or ''); local s=u:get_all('fastacl252',id)
  assert(s and s['.type']=='wifi' and owned(s),'FastACL WiFi 不存在')
  local mode,node,pre=validate_binding(u,req.node,req.preproxy)
  local split={mode=(req.node and req.node~='') and 'proxy' or s.mode,platforms=req.platforms or s.platforms or '',dns_split=req.dns_split or s.dns_split or '0',block_domains=req.block_domains or s.block_domains or '',split_mode=req.split_mode or s.split_mode or 'all',split_rules=req.split_rules or s.split_rules or ''}; require('fastacl252_split').parse(split)
  u:set('fastacl252',id,'platforms',split.platforms)
  u:set('fastacl252',id,'dns_split',split.dns_split); u:set('fastacl252',id,'block_domains',split.block_domains)
  u:set('fastacl252',id,'split_mode',split.split_mode); u:set('fastacl252',id,'split_rules',split.split_rules)
  u:set('fastacl252',id,'mode',mode); u:set('fastacl252',id,'node',node); u:set('fastacl252',id,'preproxy',pre); set_dns(u,id,req,mode)
end

function M.hide_one(u,id,hidden)
 assert(type(id)=='string' and id:match('^jfa25w%d+$'),'附加 WiFi 编号无效')
 assert(type(hidden)=='boolean','SSID 显示状态无效')
 local s=u:get_all('fastacl252',id);local w=u:get_all('wireless',id)
 assert(s and s['.type']=='wifi' and owned(s) and s.network==id,'只能修改 FastACL 建立的附加 WiFi')
 assert(w and w['.type']=='wifi-iface' and owned(w) and w.network==id and w.mode=='ap','附加 WiFi 接口不存在或不匹配')
 assert(u:set('wireless',id,'hidden',hidden and '1' or '0'),'保存 SSID 显示状态失败')
 return {id=id,hidden=hidden}
end

function M.hide_all(u,hidden)
  hidden=hidden==true or tostring(hidden)=='1'
  local count=0
  u:foreach('wireless','wifi-iface',function(s)
    if s.mode=='ap' or not s.mode then u:set('wireless',s['.name'],'hidden',hidden and '1' or '0'); count=count+1 end
  end)
  return count
end

function M.remove(u,id)
  id=tostring(id or ''); local s=u:get_all('fastacl252',id)
  assert(s and s['.type']=='wifi' and owned(s),'FastACL WiFi 不存在')
  local net=s.network; assert(net and net~='','WiFi 网络信息缺失')
  for _,cfg in ipairs(CONFIGS) do
    local del={}
    u:foreach(cfg,nil,function(x) if x['.name']==id or (owned(x) and x.jfa25_network==net) then del[#del+1]=x['.name'] end end)
    for _,name in ipairs(del) do u:delete(cfg,name) end
  end
end

-- Validate the complete batch before staging any UCI deletion.
function M.remove_many(u,ids)
 assert(type(ids)=='table' and #ids>0 and #ids<=128,'请选择 1 至 128 个附加 WiFi')
 local seen={};local main=u:get('fastacl252','main','network') or 'lan'
 for _,id in ipairs(ids) do
  assert(type(id)=='string' and id:match('^jfa25w%d+$') and not seen[id],'附加 WiFi 编号无效或重复');seen[id]=true
  local s=u:get_all('fastacl252',id)
  assert(s and s['.type']=='wifi' and owned(s) and s.network==id and id~=main and id~='lan','只能删除 FastACL 建立的附加 WiFi')
 end
 for _,id in ipairs(ids) do M.remove(u,id) end
 return {ids=ids,count=#ids}
end
function M.remove_all(u,expected)
 local ids={};u:foreach('fastacl252','wifi',function(s) if owned(s) then ids[#ids+1]=s['.name'] end end)
 assert(type(expected)=='table' and #expected==#ids,'WiFi 列表已变化，请刷新后重试');local seen={};for _,id in ipairs(expected) do assert(type(id)=='string' and not seen[id],'清除列表无效');seen[id]=true end;for _,id in ipairs(ids) do assert(seen[id],'WiFi 列表已变化，请刷新后重试') end
 table.sort(ids);return M.remove_many(u,ids)
end
function M.hide_many(u,ids,hidden)
 assert(type(ids)=='table' and #ids>0 and #ids<=128,'请选择 1 至 128 个附加 WiFi')
 assert(type(hidden)=='boolean','SSID 显示状态无效');local seen={}
 for _,id in ipairs(ids) do
  assert(type(id)=='string' and id:match('^jfa25w%d+$') and not seen[id],'附加 WiFi 编号无效或重复');seen[id]=true
  local f=u:get_all('fastacl252',id);local w=u:get_all('wireless',id)
  assert(f and f['.type']=='wifi' and owned(f) and f.network==id,'只能修改 FastACL 建立的附加 WiFi')
  assert(w and w['.type']=='wifi-iface' and owned(w) and w.network==id and w.mode=='ap','附加 WiFi 接口不存在或不匹配')
 end
 for _,id in ipairs(ids) do M.hide_one(u,id,hidden) end
 return {ids=ids,count=#ids,hidden=hidden}
end
M.owner=OWNER
-- Explicit bridge devices keep fw4 zones valid before netifd reports ifup.
-- Network references alone can be unresolved during MTWiFi boot/reload.
function M.sync_firewall_devices(u)
 local changed=0
 u:foreach('fastacl252','wifi',function(w)
  local id=w['.name'];if type(id)~='string' or not id:match('^jfa25w%d+$') or not owned(w) or w.network~=id then return end
  local n=u:get_all('network',id);local b=u:get_all('network',id..'_dev');local z=u:get_all('firewall',id)
  local bridge='br-'..id
  if not (owned(n) and n.device==bridge and owned(b) and b.name==bridge and b.type=='bridge' and owned(z) and z.name==id) then return end
  local networks=type(z.network)=='table' and z.network or {z.network};local found=false;for _,v in ipairs(networks)do if v==id then found=true end end;if not found then return end
  local devices=type(z.device)=='table' and z.device or (z.device and {z.device} or {})
  for _,v in ipairs(devices)do if v==bridge then return end end
  devices[#devices+1]=bridge;assert(u:set('firewall',id,'device',devices),'Cannot pin managed WiFi firewall device');changed=changed+1
 end)
 return changed
end
return M

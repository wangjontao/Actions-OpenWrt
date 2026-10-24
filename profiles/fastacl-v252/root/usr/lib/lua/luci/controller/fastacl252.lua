module('luci.controller.fastacl252',package.seeall)

local ACL={'juliang-fastacl252'}
local function gate(e) e.acl_depends=ACL; return e end
local function reply(data)
  local h=require 'luci.http'
  h.prepare_content('application/json')
  h.write(require('luci.jsonc').stringify(data))
end
-- O_CLOEXEC prevents service launches from retaining the request's lock FD.
-- v2 migrates away from descriptors leaked by the previous controller.
local edit_handle
local function acquire_lock(fs)
  local nx=require'nixio'
  local flags=nx.open_flags('wronly','creat')+524288 -- Linux O_CLOEXEC
  local handle=nx.open('/tmp/fastacl252-edit-v2.guard',flags,'600')
  if not handle then reply({ok=false,error='无法打开配置锁'});return false end
  if not handle:lock('tlock') then
    handle:close()
    reply({ok=false,busy=true,retry_after=1,error='上一项配置仍在应用，等待完成后自动重试'});return false
  end
  fs.mkdir('/tmp/fastacl252-edit.lock')
  if not fs.writefile('/tmp/fastacl252-edit.lock/pid',tostring(nx.getpid())) then
    handle:lock('ulock');handle:close();reply({ok=false,error='无法建立配置锁'});return false
  end
  edit_handle=handle
  return true
end
local function release_lock(fs)
  fs.remove('/tmp/fastacl252-edit.lock/pid');fs.rmdir('/tmp/fastacl252-edit.lock')
  if edit_handle then edit_handle:lock('ulock');edit_handle:close();edit_handle=nil end
end
local function tail(s,n)
  s=tostring(s or ''); n=n or 4000
  return #s>n and s:sub(-n) or s
end
local function apply_now(mode)
  local fs=require 'nixio.fs'; local sys=require 'luci.sys'
  fs.mkdir('/tmp/fastacl252')
  fs.writefile('/tmp/fastacl252/apply.result','pending')
  local rc=sys.call('/usr/bin/fastacl252 '..mode..' > /tmp/fastacl252/apply.log 2>&1')
  fs.writefile('/tmp/fastacl252/apply.result',rc==0 and '0' or '1')
  return rc==0,tail(fs.readfile('/tmp/fastacl252/apply.log') or '',5000)
end
local function provider_ok(id,scope)
  return require('fastacl252_dns').allowed(id,scope)
end
local function restore_files(fs,backup,names)
  for _,n in ipairs(names) do if backup[n]~=nil then fs.writefile('/etc/config/'..n,backup[n]) end end
end

function index()
  if not nixio.fs.access('/etc/config/fastacl252') then return end
  local p=entry({'admin','juliang','fastacl'},template('fastacl252/console'),_('FastACL 控制台'),3)
  p.dependent=false; gate(p)
  local old=gate(entry({'admin','services','fastacl252'},alias('admin','juliang','fastacl'),nil));old.leaf=true
  local e
  e=gate(entry({'admin','services','fastacl252_wireless'},call('wireless_status'),nil));e.leaf=true
  e=gate(entry({'admin','services','fastacl252_probe'},post('probe'),nil)); e.leaf=true
  e=gate(entry({'admin','services','fastacl252_status'},call('status'),nil)); e.leaf=true
  e=gate(entry({'admin','services','fastacl252_save'},post('save'),nil)); e.leaf=true
  e=gate(entry({'admin','services','fastacl252_import'},post('import_nodes'),nil)); e.leaf=true
  e=gate(entry({'admin','services','fastacl252_subscription'},post('subscription'),nil)); e.leaf=true
  e=gate(entry({'admin','services','fastacl252_delete_node'},post('delete_node'),nil)); e.leaf=true
  e=gate(entry({'admin','services','fastacl252_rename_node'},post('rename_node'),nil)); e.leaf=true
  e=gate(entry({'admin','services','fastacl252_device_name'},post('device_name'),nil)); e.leaf=true
  e=gate(entry({'admin','services','fastacl252_wifi'},post('wifi_action'),nil)); e.leaf=true
end

function status()
  local env=require 'fastacl252_env'; local u=require('uci').cursor(); local dns=require 'fastacl252_dns'; local wifi=require 'fastacl252_wifi'
  local ok,c=pcall(env.read,u,true)
  if not ok then reply({ok=false,error=tostring(c)}); return end
  local nodes={}
  -- UCI sections retain insertion order: never iterate the node map with pairs().
  u:foreach('fastacl252','node',function(section)
    local id=section['.name']; local n=c.nodes[id]
    local o=type(n.outbound)=='table' and n.outbound or {};local devs,wifis,front=0,{},0
    for _,d in ipairs(c.devices) do if d.node==id then devs=devs+1 end;if d.preproxy==id then front=front+1 end end
    for _,w in ipairs(c.wifis or {}) do if w.node==id then wifis[#wifis+1]=w.ssid or w.id end;if w.preproxy==id then front=front+1 end end
    nodes[#nodes+1]={id=id,name=n.name or id,protocol=n.protocol or '',owner=n.owner or '',retired=n.retired=='1',server=o.server or '',server_port=o.server_port,transport=type(o.transport)=='table' and o.transport.type or 'tcp',tls=type(o.tls)=='table' and o.tls.enabled==true,device_count=devs,wifi_names=wifis,front_count=front}
  end)
  local json=require 'luci.jsonc'; local fs=require 'nixio.fs'; local sys=require 'luci.sys'
  local runtime=json.parse(sys.exec('/usr/bin/fastacl252 status 2>/dev/null')) or {}
  local subscriptions={}
  u:foreach('fastacl252','subscription',function(s)
    subscriptions[#subscriptions+1]={id=s['.name'],name=s.name or s['.name'],enabled=s.enabled~='0',interval_hours=tonumber(s.interval_hours or '24'),status=json.parse(fs.readfile('/tmp/fastacl252/sub-'..s['.name']..'.json') or '') or {}}
  end)
  table.sort(subscriptions,function(a,b) return a.name<b.name end)
  local dns_stats=json.parse(require('luci.sys').exec('/usr/bin/fastacl252-dns -stats -config /tmp/fastacl252/dns.json 2>/dev/null') or '') or {}
  reply({dns_stats=dns_stats,ok=true,version='2.6.0',enabled=c.enabled,devices=env.inventory(c,u),nodes=nodes,subscriptions=subscriptions,dns_catalog=dns.catalog(),direct_dns=c.direct_dns,proxy_dns=c.proxy_dns,wifi=wifi.status(u),network=c.network,router_ip=c.router_ip,runtime=runtime,job=fs.readfile('/tmp/fastacl252/apply.result'),apply_log=tail(fs.readfile('/tmp/fastacl252/apply.log') or '',3000),subscription_history=json.parse(fs.readfile('/tmp/fastacl252/subscription-history.json') or '') or {},subscription_running=fs.access('/tmp/fastacl252-subscribe.lock') or false})
end

-- Main-LAN device changes are application-layer hot changes. dnsmasq is reloaded
-- only when a managed fixed address is actually added/removed/changed.
function save()
  local h=require 'luci.http'; local json=require 'luci.jsonc'; local fs=require 'nixio.fs'; local sys=require 'luci.sys'
  local policy=require 'fastacl252'; local env=require 'fastacl252_env'; local dns=require 'fastacl252_dns'
  local raw=h.formvalue('data') or ''
  if #raw>131072 then reply({ok=false,error='请求过大'}); return end
  local request=json.parse(raw)
  if type(request)~='table' then reply({ok=false,error='请求格式错误'}); return end
  if not acquire_lock(fs) then return end

  local u=require('uci').cursor()
  local backup={fastacl252=fs.readfile('/etc/config/fastacl252'),dhcp=fs.readfile('/etc/config/dhcp')}
  local committed=false; local dhcp_changed=false; local apply_detail=''; local enabled=false
  local ok,err=pcall(function()
    for _,cfg in ipairs({'fastacl252','dhcp'}) do local changes=u:changes(cfg); assert(not changes or not next(changes),'请先保存或撤销 LuCI 中未提交的配置') end
    local c=env.read(u); enabled=c.enabled
    if request.direct_dns then assert(provider_ok(request.direct_dns,'direct'),'国内直连 DNS 选择无效'); c.direct_dns=request.direct_dns end
    if request.proxy_dns then assert(provider_ok(request.proxy_dns,'proxy'),'代理出口 DNS 选择无效'); c.proxy_dns=request.proxy_dns end

    local updates=request.devices or {}; assert(type(updates)=='table' and #updates<=256,'设备数量过多')
    local existing={}; for _,d in ipairs(c.devices) do existing[d.mac]=d end
    local before={}; local changed={}
    for _,d in ipairs(updates) do
      local mac=assert(policy.mac(d.mac),'MAC 地址无效'); assert(not changed[mac],'重复设备'); changed[mac]=true; before[mac]=existing[mac]
      if d.remove==true then existing[mac]=nil else
        assert(type(d.name or '')=='string' and #(d.name or '')<=80,'设备名称无效')
        local node=tostring(d.node or ''); local mode=node~='' and 'proxy' or 'direct'; local dnsid=tostring(d.dns or 'inherit')
        assert(dns.valid_id(dnsid),'DNS 选择无效')
        if dnsid~='inherit' and dnsid~='custom' then
          local dp=assert(dns.provider(dnsid),'DNS 服务商不存在')
          assert(dns.allowed(dnsid,mode),'当前出口不支持此 DNS；代理出口请选择 DoH')
        end
        existing[mac]={id='d_'..mac:gsub(':',''),mac=mac,ip=d.ip,name=d.name or '',mode=mode,node=node,preproxy=d.preproxy or '',platforms=d.platforms or (existing[mac] and existing[mac].platforms) or '',dns_split=d.dns_split or (existing[mac] and existing[mac].dns_split) or '0',block_domains=d.block_domains or (existing[mac] and existing[mac].block_domains) or '',split_mode=d.split_mode or (existing[mac] and existing[mac].split_mode) or 'all',split_rules=d.split_rules or (existing[mac] and existing[mac].split_rules) or '',dns=dnsid,dns_type=d.dns_type,dns_ip=d.dns_ip,dns_name=d.dns_name}
      end
    end

    c.devices={}; for _,d in pairs(existing) do c.devices[#c.devices+1]=d end
    policy.validate(c)
    local inventory=env.inventory(c,u)
    for _,d in ipairs(c.devices) do
      u:foreach('dhcp','host',function(s)
        if s['.name']~='jfa25_'..d.id and s.ip==d.ip then
          local same=false; local list=type(s.mac)=='table' and s.mac or {s.mac or ''}
          for _,v in ipairs(list) do for x in v:gmatch('%S+') do if policy.mac(x)==d.mac then same=true end end end
          assert(same,'固定 IP 已被其他静态租约使用')
        end
      end)
      for _,r in ipairs(inventory) do assert(r.mac==d.mac or r.ip~=d.ip,'固定 IP 当前正被其他设备使用') end
    end

    if request.direct_dns then u:set('fastacl252','main','direct_dns',c.direct_dns) end
    if request.proxy_dns then u:set('fastacl252','main','proxy_dns',c.proxy_dns) end

    for mac in pairs(changed) do
      local id='d_'..mac:gsub(':',''); local host='jfa25_'..id; local old=before[mac]; local d=existing[mac]
      u:delete('fastacl252',id)
      if d then
        require('fastacl252').section(u,'fastacl252','device',id,{mac=mac,ip=d.ip,name=d.name,mode=d.mode,node=d.node or '',preproxy=d.preproxy or '',platforms=d.platforms or '',dns_split=d.dns_split or '0',block_domains=d.block_domains or '',split_mode=d.split_mode or 'all',split_rules=d.split_rules or '',dns=d.dns or 'inherit'})
        if d.dns=='custom' then
          u:set('fastacl252',id,'dns_type',d.dns_type or 'doh'); u:set('fastacl252',id,'dns_ip',d.dns_ip or ''); u:set('fastacl252',id,'dns_name',d.dns_name or '')
        end
      end

      if d then require('fastacl252_devices').save_name(u,mac,d.name or '') end

      if not d or not old or tostring(old.ip or '')~=tostring(d.ip or '') then
        dhcp_changed=true
        u:delete('dhcp',host)
        if d then
          local reserved=false
          u:foreach('dhcp','host',function(s)
            if s['.name']~=host then
              local list=type(s.mac)=='table' and s.mac or {s.mac or ''}
              for _,v in ipairs(list) do for x in v:gmatch('%S+') do if policy.mac(x)==mac then assert(s.ip==d.ip,'此 MAC 已有其他固定 IP，请先调整原静态租约'); reserved=true end end end
            end
          end)
          if not reserved then require('fastacl252').section(u,'dhcp','host',host,{mac=mac,ip=d.ip,leasetime='infinite',jfa25='1'}) end
        end
      end
    end

    assert(u:commit('fastacl252'),'保存 FastACL 配置失败'); committed=true
    if dhcp_changed then assert(u:commit('dhcp'),'保存 DHCP 配置失败') end
    fs.chmod('/etc/config/fastacl252','600'); committed=true
    if dhcp_changed then sys.call('/etc/init.d/dnsmasq reload >/dev/null 2>&1') end
    if enabled then
      local aok,detail=apply_now('hot-apply'); apply_detail=detail
      assert(aok,'应用层快速切换失败：'..(detail~='' and detail or '未知错误'))
    end
  end)

  if not ok then
    u:revert('fastacl252'); u:revert('dhcp')
    if committed then
      restore_files(fs,backup,{'fastacl252','dhcp'})
      if dhcp_changed then sys.call('/etc/init.d/dnsmasq reload >/dev/null 2>&1') end
      if enabled then apply_now('hot-apply') end
    end
  end
  release_lock(fs)
  if ok then
    reply({ok=true,message=dhcp_changed and '已保存；仅重载 DHCP，代理已应用层快速切换。' or '应用层快速切换完成；未重载 network / WiFi / firewall。',detail=apply_detail})
  else reply({ok=false,error=tostring(err),detail=apply_detail}) end
end

function import_nodes()
  local h=require 'luci.http'; local fs=require 'nixio.fs'
  local links=(h.formvalue('links') or ''):gsub('^\239\187\191','')
  if #links<1 or #links>524288 then reply({ok=false,error='导入内容为空或超过 512KB'}); return end
  -- Parsing is read-only: do it before entering the serialized commit section.
  local parsed,nodes=pcall(function() return require('fastacl252_import').batch(links) end)
  if not parsed then reply({ok=false,error=tostring(nodes)});return end
  if not acquire_lock(fs) then return end
  local u=require('uci').cursor(); local original=fs.readfile('/etc/config/fastacl252'); local count=0
  local ok,err=pcall(function()
    local pending=u:changes('fastacl252'); assert(not pending or not next(pending),'请先保存 LuCI 中未提交的 FastACL 配置')
    local manager=require 'fastacl252_nodes'; manager.check(nodes); manager.add(u,nodes)
    assert(u:commit('fastacl252'),'保存节点失败'); count=#nodes
  end)
  if not ok then u:revert('fastacl252'); if original then fs.writefile('/etc/config/fastacl252',original) end end
  fs.chmod('/etc/config/fastacl252','600'); release_lock(fs)
  local detail=not ok and (fs.readfile('/tmp/fastacl252/nodes-check.log') or '') or ''
  if #detail>3000 then detail=detail:sub(-3000) end
  reply({ok=ok,count=count,error=not ok and tostring(err) or nil,detail=not ok and detail or nil})
end

-- update = pure application hot switch; create/remove = topology cold path;
-- hide_all = wireless-only reload.
function wifi_action()
  local h=require 'luci.http'; local json=require 'luci.jsonc'; local fs=require 'nixio.fs'; local sys=require 'luci.sys'
  local req=json.parse(h.formvalue('data') or '')
  if type(req)~='table' then reply({ok=false,error='WiFi 请求格式错误'}); return end
  if not acquire_lock(fs) then return end
  local u=require('uci').cursor(); local manager=require 'fastacl252_wifi'; local result; local detail=''

  if req.action=='update' then
    local original=fs.readfile('/etc/config/fastacl252'); local committed=false
    local ok,err=pcall(function()
      local pending=u:changes('fastacl252'); assert(not pending or not next(pending),'请先保存或撤销 LuCI 中未提交配置')
      manager.update(u,req); require('fastacl252_env').read(u)
      assert(u:commit('fastacl252'),'保存 FastACL WiFi 绑定失败'); committed=true; fs.chmod('/etc/config/fastacl252','600')
      if u:get('fastacl252','main','enabled')=='1' then
        local aok,d=apply_now('hot-apply'); detail=d; assert(aok,'应用层快速切换失败：'..(d~='' and d or '未知错误'))
      end
      result={id=req.id,path='hot'}
    end)
    if not ok then
      u:revert('fastacl252')
      if committed and original then fs.writefile('/etc/config/fastacl252',original); apply_now('hot-apply') end
    end
    release_lock(fs)
    reply(ok and {ok=true,result=result,message='节点已应用层快速切换；network / WiFi / firewall 均未重载。',detail=detail} or {ok=false,error=tostring(err),detail=detail})
    return
  end

  if req.action=='hide_all' or req.action=='hide_one' or req.action=='hide_selected' then
    local original=fs.readfile('/etc/config/wireless'); local visibility_committed=false;local ok,err=pcall(function()
      local pending=u:changes('wireless'); assert(not pending or not next(pending),'请先保存或撤销无线配置')
      if req.action=='hide_one' then result=manager.hide_one(u,req.id,req.hidden);result.ids={req.id}
      elseif req.action=='hide_selected' then result=manager.hide_many(u,req.ids,req.hidden)
      else result={count=manager.hide_all(u,req.hidden)} end
      assert(u:commit('wireless'),'保存无线隐藏状态失败');visibility_committed=true
      result.apply=require('fastacl252_visibility').apply(u,result.ids or 'all')
    end)
    if not ok then u:revert('wireless'); if visibility_committed and original then fs.writefile('/etc/config/wireless',original);pcall(function() require('fastacl252_visibility').apply(require('uci').cursor(),result and result.ids or 'all')end) end end
    release_lock(fs)
    reply(ok and {ok=true,result=result,message='SSID 显示状态已更新；未重载 network / firewall / dae。'} or {ok=false,error=tostring(err)})
    return
  end

  local names={'network','wireless','dhcp','firewall','fastacl252'}; local backup={}
  for _,n in ipairs(names) do backup[n]=fs.readfile('/etc/config/'..n) end
  local committed=false
  local ok,err=pcall(function()
    for _,n in ipairs(names) do local c=u:changes(n); assert(not c or not next(c),'请先保存或撤销 LuCI 中未提交的配置') end
    if req.action=='create' then result=manager.create(u,req)
    elseif req.action=='remove' then manager.remove(u,req.id); result={id=req.id}
    elseif req.action=='remove_selected' then result=manager.remove_many(u,req.ids)
    elseif req.action=='remove_all' then result=manager.remove_all(u,req.ids)
    else error('不支持的 WiFi 操作') end
    require('fastacl252_env').read(u)
    committed=true
    for _,n in ipairs(names) do assert(u:commit(n),'保存 '..n..' 配置失败') end
    assert(sys.call('/etc/init.d/network reload >/dev/null 2>&1')==0,'network reload 失败')
    sys.call('wifi reload >/dev/null 2>&1')
    sys.call('/etc/init.d/dnsmasq restart >/dev/null 2>&1')
    sys.call('/etc/init.d/firewall restart >/dev/null 2>&1')
    if u:get('fastacl252','main','enabled')=='1' then
      local aok,d=apply_now('cold-apply'); detail=d; assert(aok,'拓扑应用失败：'..(d~='' and d or '未知错误'))
    end
  end)
  if not ok then
    for _,n in ipairs(names) do u:revert(n) end
    if committed then
      restore_files(fs,backup,names)
      sys.call('/etc/init.d/network reload >/dev/null 2>&1'); sys.call('wifi reload >/dev/null 2>&1'); sys.call('/etc/init.d/dnsmasq restart >/dev/null 2>&1'); sys.call('/etc/init.d/firewall restart >/dev/null 2>&1')
      if u:get('fastacl252','main','enabled')=='1' then apply_now('cold-apply') end
    end
  end
  release_lock(fs)
  reply(ok and {ok=true,result=result,message='WiFi 拓扑已保存并重新加载。',detail=detail} or {ok=false,error=tostring(err),detail=detail})
end

function subscription()
  local h=require 'luci.http'; local fs=require 'nixio.fs'; local policy=require 'fastacl252'; local sys=require 'luci.sys'
  local data=require('luci.jsonc').parse(h.formvalue('data') or '')
  if type(data)~='table' then reply({ok=false,error='订阅请求格式错误'}); return end
  local u=require('uci').cursor()
  if data.action=='update' then
    local id=data.id or 'all'
    if id~='all' and (not policy.id(id) or u:get('fastacl252',id)~='subscription') then reply({ok=false,error='订阅 ID 无效'}); return end
    if fs.access('/tmp/fastacl252-subscribe.lock') then reply({ok=false,error='订阅正在更新'}); return end
    sys.call('lua /usr/libexec/fastacl252-subscribe.lua '..id..' >/tmp/fastacl252-subscribe.log 2>&1 </dev/null &')
    reply({ok=true,message='订阅更新已开始'}); return
  end
  if not acquire_lock(fs) then return end
  local original=fs.readfile('/etc/config/fastacl252')
  local ok,err=pcall(function()
    local pending=u:changes('fastacl252'); assert(not pending or not next(pending),'请先保存未提交配置')
    local id=data.id
    if id then assert(policy.id(id) and u:get('fastacl252',id)=='subscription','订阅 ID 无效') end
    if data.action=='remove' then
      assert(id,'缺少订阅 ID'); local owned,remove={},{}
      u:foreach('fastacl252','node',function(n) if n.owner==id then owned[n['.name']]=true; remove[#remove+1]=n['.name'] end end)
      u:foreach('fastacl252','device',function(d) assert(not owned[d.node] and not owned[d.preproxy],'订阅仍有设备绑定，请先解除绑定') end)
      u:foreach('fastacl252','wifi',function(w) assert(not owned[w.node] and not owned[w.preproxy],'订阅仍有 WiFi 绑定，请先解除绑定') end)
      for _,n in ipairs(remove) do u:delete('fastacl252',n) end; u:delete('fastacl252',id)
    else
      assert(data.action=='save','订阅操作无效')
      local hours=tonumber(data.interval_hours or 24); assert(hours and hours>=1 and hours<=168 and hours%1==0,'更新周期须为 1–168 小时')
      local name=data.name or ''; assert(type(name)=='string' and #name>0 and #name<=80,'订阅名称无效')
      local url=data.url; if not url or url=='' then url=id and u:get('fastacl252',id,'url') end
      assert(type(url)=='string' and #url<=4096 and url:match('^https://') and not url:find('[%c"\\]'),'订阅必须使用 HTTPS')
      if not id then local count=0; u:foreach('fastacl252','subscription',function() count=count+1 end); assert(count<32,'最多 32 个订阅'); id=u:add('fastacl252','subscription') end
      u:set('fastacl252',id,'name',name); u:set('fastacl252',id,'url',url); u:set('fastacl252',id,'interval_hours',tostring(hours)); u:set('fastacl252',id,'enabled',data.enabled==false and '0' or '1')
    end
    assert(u:commit('fastacl252'),'保存订阅失败'); fs.chmod('/etc/config/fastacl252','600')
  end)
  if not ok then u:revert('fastacl252'); if original then fs.writefile('/etc/config/fastacl252',original) end end
  release_lock(fs); reply({ok=ok,error=not ok and tostring(err) or nil})
end

-- A label edit never changes node IDs, credentials, routing or active bindings.
-- Label-only changes do not invoke hot-apply, DHCP or any network service.
function device_name()
  local h=require'luci.http';local fs=require'nixio.fs';local u=require('uci').cursor()
  if not acquire_lock(fs) then return end
  local original=fs.readfile('/etc/config/fastacl252');local name
  local ok,err=pcall(function()
    local pending=u:changes('fastacl252');assert(not pending or not next(pending),'请先保存未提交的 FastACL 配置')
    local mac=assert(require('fastacl252').mac(h.formvalue('mac')),'设备 MAC 无效')
    local env=require'fastacl252_env';local known=false
    for _,d in ipairs(env.inventory(env.read(u,true),u)) do if d.mac==mac then known=true;break end end
    assert(known,'设备已不在列表，请刷新后重试')
    name=require('fastacl252_devices').save_name(u,mac,h.formvalue('name'))
    assert(u:commit('fastacl252'),'保存设备备注失败')
  end)
  if not ok then u:revert('fastacl252');if original then fs.writefile('/etc/config/fastacl252',original) end end
  fs.chmod('/etc/config/fastacl252','600');release_lock(fs)
  reply({ok=ok,name=ok and name or nil,error=not ok and tostring(err) or nil})
end

function rename_node()
  local h=require'luci.http';local fs=require'nixio.fs'
  if not acquire_lock(fs) then return end
  local u=require('uci').cursor();local original=fs.readfile('/etc/config/fastacl252')
  local ok,err=pcall(function()
    local pending=u:changes('fastacl252');assert(not pending or not next(pending),'请先保存未提交的 FastACL 配置')
    require('fastacl252_nodes').rename(u,h.formvalue('id'),h.formvalue('name'))
    assert(u:commit('fastacl252'),'保存节点名称失败')
  end)
  if not ok then u:revert('fastacl252');if original then fs.writefile('/etc/config/fastacl252',original) end end
  fs.chmod('/etc/config/fastacl252','600');release_lock(fs)
  reply({ok=ok,error=not ok and tostring(err) or nil})
end

function delete_node()
  local fs=require 'nixio.fs'; local id=require('luci.http').formvalue('id'); local policy=require 'fastacl252'
  if not policy.id(id) then reply({ok=false,error='节点 ID 无效'}); return end
  if not acquire_lock(fs) then return end
  local u=require('uci').cursor(); local ok,err=pcall(function()
    local pending=u:changes('fastacl252'); assert(not pending or not next(pending),'请先保存配置')
    assert(u:get('fastacl252',id)=='node','节点不存在')
    u:foreach('fastacl252','device',function(d) assert(d.node~=id and d.preproxy~=id,'节点仍被设备使用，请先解除绑定') end)
    u:foreach('fastacl252','wifi',function(w) assert(w.node~=id and w.preproxy~=id,'节点仍被 WiFi 使用，请先解除绑定') end)
    u:delete('fastacl252',id); assert(u:commit('fastacl252'),'删除节点失败')
  end)
  if not ok then u:revert('fastacl252') end
  release_lock(fs); reply({ok=ok,error=not ok and tostring(err) or nil})
end

-- Read-only saved-node/assigned-exit probe. Never changes client bindings.
function probe()
 local h=require'luci.http'; local fs=require'nixio.fs'; local sys=require'luci.sys';local json=require'luci.jsonc'
 if not fs.mkdir('/tmp/fastacl252-probe.lock') then reply({ok=false,error='已有出口检测正在进行，请稍后重试'});return end
 local result
 local ok,err=pcall(function()
  local c=require('fastacl252_env').read();local kind=h.formvalue('kind');local target=h.formvalue('id');local x;local mode='proxy'
  if kind=='node' then assert(require('fastacl252').id(target) and c.nodes[target],'节点不存在');x={node=target}
  elseif kind=='device' then
   local mac=assert(require('fastacl252').mac(target),'设备 MAC 无效')
   for _,d in ipairs(c.devices) do if d.mac==mac then x=d;mode=d.mode;break end end
   if not x then x={};mode='direct' end
  else error('检测类型无效') end
  local link=''
  if mode=='proxy' then
   local compiler=require'fastacl252_dae';link=compiler.link(assert(c.nodes[x.node],'绑定节点不存在'))
   if x.preproxy and x.preproxy~='' then link=link..' -> '..compiler.link(assert(c.nodes[x.preproxy],'前置节点不存在')) end
  end
  assert(fs.writefile('/tmp/fastacl252-probe.lock/spec.json',json.stringify({link=link})),'写入检测配置失败');fs.chmod('/tmp/fastacl252-probe.lock/spec.json','600')
  local data=sys.exec('/usr/libexec/fastacl252-exit-probe -probe-file /tmp/fastacl252-probe.lock/spec.json 2>/dev/null')
  result=json.parse(data);assert(type(result)=='table','检测程序未返回结果')
  result.kind=kind;result.mode=mode;result.scope='saved_exit';result.note=kind=='device' and '路由器侧检测已保存的绑定出口，不代表手机实机连通性' or '路由器侧节点出口检测'
 end)
 fs.remove('/tmp/fastacl252-probe.lock/spec.json');fs.rmdir('/tmp/fastacl252-probe.lock')
 if ok then reply(result) else reply({ok=false,error='出口检测失败，请检查设备绑定和节点状态'}) end
end

function wireless_status()
 local ok,result=pcall(require('fastacl252_wireless').read)
 reply(ok and result or {ok=false,error='读取无线设备信息失败'})
end

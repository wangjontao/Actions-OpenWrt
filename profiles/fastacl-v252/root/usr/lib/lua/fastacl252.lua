-- FastACL 2.5.5 policy compiler: main-LAN device policies + managed WiFi subnet policies.
local M={}
-- libuci's native cursor has set/add but no LuCI-specific section() helper.
function M.section(u,config,kind,name,values)
  assert(M.id(name),'Invalid UCI section name')
  assert(u:set(config,name,kind),'Cannot create UCI section: '..config..'.'..name)
  for key,value in pairs(values or {}) do
    assert(u:set(config,name,key,value),'Cannot set UCI option: '..config..'.'..name..'.'..key)
  end
  return name
end
function M.ipnum(s)
  local a,b,c,d=tostring(s or ''):match('^(%d+)%.(%d+)%.(%d+)%.(%d+)$')
  a,b,c,d=tonumber(a),tonumber(b),tonumber(c),tonumber(d)
  if not a or a>255 or b>255 or c>255 or d>255 then return nil end
  return ((a*256+b)*256+c)*256+d
end
function M.mac(s)
  s=tostring(s or ''):upper()
  if not s:match('^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$') then return nil end
  if tonumber(s:sub(1,2),16)%2~=0 or s=='00:00:00:00:00:00' then return nil end
  return s
end
function M.id(s) return type(s)=='string' and s:match('^[%w_]+$') and #s<=64 end
function M.dev(s) return type(s)=='string' and s:match('^[%w_.:-]+$') and #s<=32 end
function M.prefix(mask)
  local p=tonumber(mask); if p and p>=1 and p<=30 and p%1==0 then return p end
  local n=M.ipnum(mask); if not n then return nil end
  local pfx=0; local zero=false
  for i=31,0,-1 do local b=math.floor(n/2^i)%2
    if b==0 then zero=true elseif zero then return nil else pfx=pfx+1 end
  end
  return pfx>=1 and pfx<=30 and pfx or nil
end
function M.in_lan(ip,router,mask)
  local n,r,p=M.ipnum(ip),M.ipnum(router),M.prefix(mask)
  if not n or not r or not p then return false end
  local size=2^(32-p); local base=math.floor(r/size)*size
  return n>base and n<base+size-1 and n~=r
end
function M.cidr(ip,mask)
  local p=assert(M.prefix(mask)); local n=assert(M.ipnum(ip)); n=math.floor(n/2^(32-p))*2^(32-p)
  return string.format('%d.%d.%d.%d/%d',math.floor(n/16777216)%256,math.floor(n/65536)%256,math.floor(n/256)%256,n%256,p)
end
local function cidr_range(cidr)
  local ip,p=tostring(cidr or ''):match('^([^/]+)/(%d+)$'); p=tonumber(p)
  local n=M.ipnum(ip); if not n or not p or p<1 or p>30 then return nil end
  local size=2^(32-p); local base=math.floor(n/size)*size
  return base,base+size-1
end
local function validate_exit(c,x,guards_only)
  require('fastacl252_split').parse(x)
  assert(x.mode=='direct' or x.mode=='proxy','Invalid policy mode')
  if x.mode=='proxy' and not guards_only then
    assert(M.id(x.node) and c.nodes[x.node],'Missing proxy node')
    if x.preproxy and x.preproxy~='' then
      assert(M.id(x.preproxy) and c.nodes[x.preproxy] and x.preproxy~=x.node,'Invalid preproxy')
      local p=c.nodes[x.node].protocol
      assert(p=='socks' or p=='http','Preproxy supported for SOCKS5/HTTP landing nodes')
    end
  end
end
function M.validate(c,guards_only)
  assert(M.id(c.network),'Invalid LAN network')
  assert(M.dev(c.interface),'LAN interface unavailable')
  assert(M.ipnum(c.router_ip) and M.prefix(c.netmask),'Static IPv4 LAN required')
  assert(tonumber(c.port) and c.port>=1024 and c.port<=65535 and c.port%1==0,'Invalid port')
  assert(c.port~=12553 and (c.port<12600 or c.port>=14000),'Port reserved for encrypted DNS')
  assert(c.default_mode=='direct','Default mode must be direct')
  assert(c.dns_policy=='direct' or c.dns_policy=='private','Invalid legacy DNS policy')
  for _,key in ipairs({'dns_server','private_dns_server'}) do assert(M.ipnum(c[key]),'DNS endpoint must be IPv4: '..key) end
  for _,key in ipairs({'dns_name','private_dns_name'}) do assert(type(c[key])=='string' and c[key]:match('^[%w.-]+$'),'Invalid TLS name') end
  local dns=require 'fastacl252_dns'; local sink={}
  dns.resolve({},'direct',c,sink,'global_direct'); dns.resolve({},'proxy',c,sink,'global_proxy')
  local seenif={}; for _,v in ipairs(c.interfaces or {c.interface}) do assert(M.dev(v),'Invalid LAN interface'); seenif[v]=true end
  assert(seenif[c.interface],'Primary LAN interface missing')
  local seenip,seenmac={},{}
  for _,d in ipairs(c.devices) do
    assert(M.mac(d.mac)==d.mac,'Invalid MAC')
    assert(M.in_lan(d.ip,c.router_ip,c.netmask),'Device IP outside LAN / router / network / broadcast')
    assert(not seenip[d.ip] and not seenmac[d.mac],'Duplicate device IP or MAC')
    seenip[d.ip],seenmac[d.mac]=true,true
    validate_exit(c,d,guards_only)
    local did=tostring(d.id or d.mac or d.ip or 'device'):gsub('[^%w_]','_')
    dns.resolve(d,d.mode,c,sink,'device_'..did)
  end
  local ranges={}; do local a,b=cidr_range(M.cidr(c.router_ip,c.netmask)); ranges[#ranges+1]={a,b,c.network} end
  local seennet={}
  for _,w in ipairs(c.wifis or {}) do
    assert(M.id(w.id) and M.id(w.network),'Invalid WiFi policy ID')
    assert(not seennet[w.network],'Duplicate WiFi network'); seennet[w.network]=true
    assert(M.dev(w.interface),'Managed WiFi interface unavailable')
    assert(M.ipnum(w.router_ip) and M.prefix(w.netmask),'Managed WiFi requires static IPv4')
    local actual=M.cidr(w.router_ip,w.netmask); assert(actual==w.subnet,'Managed WiFi subnet mismatch')
    local a,b=assert(cidr_range(w.subnet)); for _,r in ipairs(ranges) do assert(b<r[1] or a>r[2],'WiFi subnet overlaps '..r[3]) end; ranges[#ranges+1]={a,b,w.network}
    validate_exit(c,w,guards_only); dns.resolve(w,w.mode,c,sink,'wifi_'..w.id)
  end
  return c
end
function M.compile(c) M.validate(c); return require('fastacl252_dae').compile(c) end

local function quote_iface(s) return '"'..s..'"' end
local function nft_set(name,kind,values)
  return 'set '..name..' { type '..kind..';'..(#values>0 and ' elements = { '..table.concat(values,', ')..' };' or '')..' }\n'
end
function M.firewall(c,backend)
  M.validate(c,true); assert(backend=='nft','Invalid firewall backend')
  local proxy={}; for _,d in ipairs(c.devices) do if d.mode=='proxy' then proxy[#proxy+1]=d end end
  local macs,ips,pairs={},{},{}; for _,d in ipairs(proxy) do macs[#macs+1]=d.mac;ips[#ips+1]=d.ip;pairs[#pairs+1]=d.mac..' . '..d.ip end
  local ifaces,proxy_wifi={},{}; local seen={}
  for _,v in ipairs(c.interfaces or {c.interface}) do if not seen[v] then ifaces[#ifaces+1]=quote_iface(v);seen[v]=true end end
  for _,w in ipairs(c.wifis or {}) do if w.mode=='proxy' then proxy_wifi[#proxy_wifi+1]=quote_iface(w.interface) end end
  local wifi_set,wifi_drop='',''
  if #proxy_wifi>0 then
    wifi_set=nft_set('proxy_wifi_ifaces','ifname',proxy_wifi)
    wifi_drop='iifname @proxy_wifi_ifaces drop\n'
  end
  local sets=nft_set('lan_ifaces','ifname',ifaces)..wifi_set..nft_set('proxy_macs','ether_addr',macs)..nft_set('proxy_ips','ipv4_addr',ips)..nft_set('proxy_pairs','ether_addr . ipv4_addr',pairs)
  local all='iifname @lan_ifaces '; local main='iifname '..quote_iface(c.interface)..' '
  local dns6=all..'meta nfproto ipv6 meta l4proto { tcp, udp } th dport 53 drop\n'
  local split_sets,split_rules=require('fastacl252_split').nft(c)
  return {nft='table inet fastacl252 {\n'..sets..split_sets..
    'chain prerouting { type filter hook prerouting priority -151; policy accept;\n'..
    all..'udp sport 68 udp dport 67 return\n'..
    main..'meta nfproto ipv4 ether saddr @proxy_macs ether saddr . ip saddr != @proxy_pairs drop\n'..
    main..'meta nfproto ipv4 ip saddr @proxy_ips ether saddr . ip saddr != @proxy_pairs drop\n}\n'..
    'chain forward { type filter hook forward priority -10; policy accept;\n'..dns6..split_rules..
    wifi_drop..
    main..'ether saddr @proxy_macs drop\n'..main..'ip saddr @proxy_ips drop\n}\n'..
    'chain dns_redirect { type nat hook prerouting priority -100; policy accept;\n'..
    all..'meta nfproto ipv4 meta l4proto { tcp, udp } th dport 53 redirect to :12553\n}\n'..
    'chain input { type filter hook input priority -10; policy accept;\n'..dns6..'}\n}\n'}
end
return M

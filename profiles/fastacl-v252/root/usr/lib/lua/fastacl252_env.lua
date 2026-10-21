local M={}
local json=require 'luci.jsonc'
local sys=require 'luci.sys'
local util=require 'luci.util'
local policy=require 'fastacl252'

local function status_for(net,u)
  local st=json.parse(sys.exec('ubus call network.interface.'..net..' status 2>/dev/null')) or {}
  local addr=u:get('network',net,'ipaddr'); if type(addr)=='table' then addr=addr[1] end
  local mask=u:get('network',net,'netmask') or '255.255.255.0'
  return st.l3_device or u:get('network',net,'device'),addr,mask
end

function M.read(u,guards_only)
  u=u or require('uci').cursor()
  local main=u:get_all('fastacl252','main') or {}
  local net=main.network or 'lan'; assert(policy.id(net),'Invalid network')
  local iface,addr,mask=status_for(net,u)
  local c={network=net,interface=iface,interfaces={},router_ip=addr,netmask=mask,port=tonumber(main.port or 12525),enabled=main.enabled=='1',default_mode=main.default_mode or 'direct',dns_policy=main.dns_policy or 'private',dns_server=main.dns_server or '223.5.5.5',dns_name=main.dns_name or 'dns.alidns.com',private_dns_server=main.private_dns_server or '1.1.1.1',private_dns_name=main.private_dns_name or 'cloudflare-dns.com',direct_dns=main.direct_dns or 'alidns',proxy_dns=main.proxy_dns or 'cloudflare',devices={},wifis={},nodes={}}
  if iface and iface~='' then c.interfaces[#c.interfaces+1]=iface end
  u:foreach('fastacl252','node',function(n)
    n.outbound=json.parse(n.outbound or '')
    c.nodes[n['.name']]=n
  end)
  u:foreach('fastacl252','device',function(d)
    c.devices[#c.devices+1]={id=d['.name'],mac=policy.mac(d.mac),ip=d.ip,name=d.name or '',mode=d.mode or 'direct',node=d.node,preproxy=d.preproxy,platforms=d.platforms or '',dns_split=d.dns_split or '0',block_domains=d.block_domains or '',split_mode=d.split_mode or 'all',split_rules=d.split_rules or '',dns=d.dns or 'inherit',dns_type=d.dns_type,dns_ip=d.dns_ip,dns_name=d.dns_name}
  end)
  u:foreach('fastacl252','wifi',function(w)
    local wn=w.network or w['.name']; local wi,wip,wmask=status_for(wn,u)
    local subnet=w.subnet
    if not subnet and wip and policy.ipnum(wip) and policy.prefix(wmask) then subnet=policy.cidr(wip,wmask) end
    c.wifis[#c.wifis+1]={id=w['.name'],network=wn,interface=wi,router_ip=wip,netmask=wmask,subnet=subnet,ssid=w.ssid or '',band=w.band or '',mode=w.mode or 'direct',node=w.node,preproxy=w.preproxy,platforms=w.platforms or '',dns_split=w.dns_split or '0',block_domains=w.block_domains or '',split_mode=w.split_mode or 'all',split_rules=w.split_rules or '',dns=w.dns or 'inherit',dns_type=w.dns_type,dns_ip=w.dns_ip,dns_name=w.dns_name}
    if wi and wi~='' then c.interfaces[#c.interfaces+1]=wi end
  end)
  table.sort(c.devices,function(a,b) return tostring(a.mac)<tostring(b.mac) end)
  table.sort(c.wifis,function(a,b) return a.id<b.id end)
  if not guards_only then c.platform_secret=require('fastacl252_slots').key() end
  return policy.validate(c,guards_only)
end

function M.inventory(c,u)
  u=u or require('uci').cursor(); local rows={}; local function row(mac)
    mac=policy.mac(mac); if not mac then return nil end
    rows[mac]=rows[mac] or {mac=mac,name='',ip='',online=false,bound=false,mode='direct',dns='inherit'}; return rows[mac]
  end
  local f=io.open('/tmp/dhcp.leases'); if f then
    for l in f:lines() do local exp,mac,ip,name=l:match('^(%d+)%s+(%S+)%s+(%S+)%s+(%S+)')
      if exp and (tonumber(exp)==0 or tonumber(exp)>os.time()) and policy.in_lan(ip,c.router_ip,c.netmask) then local r=row(mac); if r then r.ip=ip; r.name=name~='*' and name or ''; r.hostname=r.name; r.source='lease' end end
    end; f:close()
  end
  for l in sys.exec('ip -4 neigh show dev '..util.shellquote(c.interface)..' 2>/dev/null'):gmatch('[^\n]+') do
    local ip,mac=l:match('^(%S+).-lladdr%s+(%S+)')
    if ip and policy.in_lan(ip,c.router_ip,c.netmask) then local r=row(mac); if r then r.ip=ip; r.online=l:find('REACHABLE',1,true)~=nil or l:find('DELAY',1,true)~=nil or l:find('PROBE',1,true)~=nil; r.neighbor_state=l:match('(%u+)%s*$') end end
  end
  for _,d in ipairs(c.devices) do local r=row(d.mac); if r then r.platforms=d.platforms or '';r.dns_split=d.dns_split or '0'; r.block_domains=d.block_domains or ''; r.split_mode=d.split_mode or 'all'; r.split_rules=d.split_rules or ''; r.bound=true; r.fixed_ip=d.ip; r.ip=r.ip~='' and r.ip or d.ip; r.name=d.name~='' and d.name or r.name; r.mode=d.mode; r.node=d.node or ''; r.preproxy=d.preproxy or ''; r.dns=d.dns or 'inherit'; r.dns_type=d.dns_type or ''; r.dns_ip=d.dns_ip or ''; r.dns_name=d.dns_name or ''; r.renew_required=r.ip~=d.ip end end
  u:foreach('fastacl252','device_alias',function(a)
    local mac=policy.mac(a.mac);local r=mac and rows[mac]
    if r and type(a.name)=='string' and a.name~='' then r.name=a.name;r.custom_name=a.name end
  end)
  local out={}; for _,r in pairs(rows) do out[#out+1]=r end
  table.sort(out,function(a,b) if a.bound~=b.bound then return a.bound end; return a.mac<b.mac end)
  return out
end
return M

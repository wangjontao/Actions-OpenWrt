-- Native dae configuration compiler for FastACL 2.5.5.
-- Supports the primary LAN plus independently routed managed WiFi subnets.
local M={}
local function quote(s)
  assert(type(s)=='string' and #s>0 and #s<=8192,'Invalid dae string')
  assert(not s:find('[%z\1-\31\127]'),'Control character in dae string')
  return "'"..s:gsub('\\','\\\\'):gsub("'","\\'").."'"
end
local function id(s)
  assert(type(s)=='string' and #s<=64 and s:match('^[%w_]+$'),'Invalid node ID')
  return s
end
function M.link(n)
  local uri=n.dae_uri or require('fastacl252_uri').node(n)
  local scheme=uri:match('^([%w]+)://')
  local supported={socks=true,socks5=true,http=true,https=true,ss=true,vmess=true,vless=true,trojan=true,tuic=true,hysteria2=true,hy2=true,anytls=true}
  assert(supported[scheme],'Unsupported dae URI scheme')
  assert(not uri:find(' -> ',1,true),'Nested chain in imported node')
  quote(uri); return uri
end

function M.compile(c)
  local policy=require 'fastacl252'; policy.validate(c)
  local dns=require 'fastacl252_dns'
  local nodes,groups,rules,used={},{},{},{}
  local resolvers={}
  local relay={listen='0.0.0.0:12553',direct_ip=c.dns_server,direct_name=c.dns_name,private_ip=c.private_dns_server,private_name=c.private_dns_name,devices={},exits={},resolvers=resolvers,device_policies={},network_policies={}}
  local routes={}; local nextid=12600
  local function ensure_exit(x)
    local name='exit_'..id(x.node); local uri=M.link(assert(c.nodes[x.node],'Missing exit node'))
    if x.preproxy and x.preproxy~='' then
      assert(x.preproxy~=x.node,'Self-referencing chain')
      local exit=c.nodes[x.node]; assert(exit.protocol=='socks' or exit.protocol=='http','Chain requires SOCKS/HTTP landing')
      uri=uri..' -> '..M.link(assert(c.nodes[x.preproxy],'Missing front node'))
      name=name..'_via_'..id(x.preproxy)
    end
    if not used[name] then
      nodes[#nodes+1]=name..': '..quote(uri)
      groups[#groups+1]=name..' { filter: name('..quote(name)..')\n policy: fixed(0)\n}'
      used[name]=true; routes[name]=nextid; relay.exits[tostring(nextid)]=uri; nextid=nextid+1
    end
    return name,routes[name]
  end
  local default_resolver=dns.resolve({},'direct',c,resolvers,'default')
  relay.default_policy={resolver=default_resolver,exit=0}
  -- DNS is intercepted by nft and delivered to the local encrypted relay.
  rules[#rules+1]='sport(68) && dport(67) -> must_direct'
  rules[#rules+1]='dip('..policy.cidr(c.router_ip,c.netmask)..') -> must_direct'
  for _,w in ipairs(c.wifis or {}) do rules[#rules+1]='dip('..w.subnet..') -> must_direct' end
  rules[#rules+1]='dip(224.0.0.0/4, 255.255.255.255) -> must_direct'
  rules[#rules+1]='dport(53) -> must_direct'
  for _,d in ipairs(c.devices) do
    local port=0; local name
    if d.mode=='proxy' then
      name,port=ensure_exit(d)
      local mac='mac('..quote(d.mac)..')'; local ip='sip('..d.ip..'/32)'
      rules[#rules+1]=mac..' && !'..ip..' -> block'
      rules[#rules+1]=ip..' && !'..mac..' -> block'
      rules[#rules+1]=mac..' && '..ip..' -> must_'..name
      -- Legacy private-DNS mode consumed this map.  Dev.2 uses the explicit
      -- device_policies map for normal/per-device DNS so keep the old map
      -- empty unless the old private-DNS compatibility path is selected.
      if c.dns_policy=='private' then relay.devices[d.ip]=port end
    end
    local did=tostring(d.id or d.mac or d.ip or 'device'):gsub('[^%w_]','_')
    local resolver=dns.resolve(d,d.mode,c,resolvers,'device_'..did)
    relay.device_policies[d.ip]={resolver=resolver,exit=port}
  end
  for _,w in ipairs(c.wifis or {}) do
    local port=0
    if w.mode=='proxy' then local name; name,port=ensure_exit(w); rules[#rules+1]='sip('..w.subnet..') -> must_'..name end
    local resolver=dns.resolve(w,w.mode,c,resolvers,'wifi_'..w.id)
    relay.network_policies[w.subnet]={resolver=resolver,exit=port}
  end
  rules[#rules+1]='fallback: must_direct'
  local interfaces=table.concat(c.interfaces or {c.interface},',')
  local conf='global {\n disable_waiting_network: true\n auto_config_kernel_parameter: true\n so_mark_from_dae: 0\n dial_mode: ip\n lan_interface: '..quote(interfaces)..'\n log_level: warn\n tproxy_port: '..tostring(c.port)..'\n tproxy_port_protect: true\n bootstrap_resolver: \'127.0.0.1:12553\'\n fallback_resolver: \'127.0.0.1:12553\'\n}\nnode {\n'..table.concat(nodes,'\n')..'\n}\ngroup {\n'..table.concat(groups,'\n')..'\n}\nrouting {\n'..table.concat(rules,'\n')..'\n}\n'
  return conf,relay
end
-- Go relay map fields must be JSON objects, including when empty.
function M.encode_relay(relay)
  local json=require 'luci.jsonc'
  local maps={devices=true,exits=true,resolvers=true,device_policies=true,network_policies=true}
  local function object(t)
    local keys,fields={},{}
    for k in pairs(t) do keys[#keys+1]=k end
    table.sort(keys)
    for _,k in ipairs(keys) do fields[#fields+1]=json.stringify(k)..':'..json.stringify(t[k]) end
    return '{'..table.concat(fields,',')..'}'
  end
  local keys,fields={},{}
  for k in pairs(relay) do keys[#keys+1]=k end
  table.sort(keys)
  for _,k in ipairs(keys) do
    fields[#fields+1]=json.stringify(k)..':'..(maps[k] and object(relay[k]) or json.stringify(relay[k]))
  end
  return '{'..table.concat(fields,',')..'}'
end
return M

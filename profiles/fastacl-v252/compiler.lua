-- Native dae configuration compiler. This module never enables a service.
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
  -- Require the importer to supply a checked native URI. Do not silently
  -- translate fields whose meaning differs between proxy implementations.
  local uri=assert(n.dae_uri,'Native dae URI unavailable')
  local scheme=uri:match('^([%w]+)://')
  local supported={socks=true,socks5=true,http=true,https=true,ss=true,
    vmess=true,vless=true,trojan=true,tuic=true,hysteria2=true,hy2=true,anytls=true}
  assert(supported[scheme],'Unsupported dae URI scheme')
  assert(not uri:find(' -> ',1,true),'Nested chain in imported node')
  quote(uri)
  return uri
end
function M.compile(c)
  assert(type(c.interface)=='string' and c.interface:match('^[%w_.:-]+$'),'Invalid LAN interface')
  assert(c.dns_policy=='direct','Private DNS adapter is not ready')
  assert(c.default_mode=='direct','Default mode must be direct')
  local nodes,groups,rules,used,ips,macs={},{},{},{},{},{}
  -- DNS is delivered to the encrypted local relay, outside dae DNS hijacking.
  rules[#rules+1]='dport(53) -> must_direct'
  for _,d in ipairs(c.devices) do
    assert(d.mac:match('^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$') and tonumber(d.mac:sub(1,2),16)%2==0 and d.mac~='00:00:00:00:00:00','Invalid device MAC')
    assert(d.ip:match('^%d+%.%d+%.%d+%.%d+$'),'Invalid device IP')
    for octet in d.ip:gmatch('%d+') do assert(tonumber(octet)<=255 and tostring(tonumber(octet))==octet,'Invalid device IP') end
    assert(not ips[d.ip] and not macs[d.mac:upper()],'Duplicate device identity')
    ips[d.ip],macs[d.mac:upper()]=true,true
    assert(d.mode=='direct' or d.mode=='proxy','Invalid device mode')
    if d.mode=='proxy' then
      local name='exit_'..id(d.node)
      local uri=M.link(assert(c.nodes[d.node],'Missing exit node'))
      if d.preproxy and d.preproxy~='' then
        assert(d.preproxy~=d.node,'Self-referencing chain')
        local exit=c.nodes[d.node]
        assert(exit.protocol=='socks' or exit.protocol=='http','Chain requires SOCKS/HTTP landing')
        uri=M.link(assert(c.nodes[d.preproxy],'Missing front node'))..' -> '..uri
        name=name..'_via_'..id(d.preproxy)
      end
      if not used[name] then
        nodes[#nodes+1]=name..': '..quote(uri)
        groups[#groups+1]=name..' { filter: name('..quote(name)..')\n policy: fixed(0)\n}'
        used[name]=true
      end
      local mac='mac('..quote(d.mac)..')'
      local ip='sip('..d.ip..'/32)'
      rules[#rules+1]=mac..' && !'..ip..' -> block'
      rules[#rules+1]=ip..' && !'..mac..' -> block'
      rules[#rules+1]=mac..' && '..ip..' -> must_'..name
    end
  end
  rules[#rules+1]='fallback: must_direct'
  return 'global {\n lan_interface: '..quote(c.interface)..'\n log_level: warn\n tproxy_port: 12525\n tproxy_port_protect: true\n bootstrap_resolver: \'127.0.0.1:12553\'\n fallback_resolver: \'127.0.0.1:12553\'\n}\nnode {\n'..table.concat(nodes,'\n')..'\n}\ngroup {\n'..table.concat(groups,'\n')..'\n}\nrouting {\n'..table.concat(rules,'\n')..'\n}\n'
end
return M

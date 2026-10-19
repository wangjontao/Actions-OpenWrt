local M={}
local json=require 'luci.jsonc'
local function decode(s)
  assert(not s:find('%%[^%x]') and not s:find('%%$') and not s:find('%%%x$'),'Invalid percent encoding')
  return (s:gsub('%%(%x%x)',function(h) return string.char(tonumber(h,16)) end))
end
local function b64(s)
  s=s:gsub('-','+'):gsub('_','/'); s=s..string.rep('=',(4-#s%4)%4)
  local v=require('nixio').bin.b64decode(s); assert(type(v)=='string' and #v>0,'Invalid base64'); return v
end
local function endpoint(s)
  local host,port=s:match('^%[([^%]]+)%]:(%d+)$')
  if not host then host,port=s:match('^([^:/%s]+):(%d+)$') end
  port=tonumber(port); assert(host and port and port>=1 and port<=65535,'Invalid server/port')
  return host,port
end
local function transport(o,p)
  local t=p.type or p.net or 'tcp'
  if t=='tcp' or t=='raw' or t=='none' then return end
  if t=='ws' then o.transport={type='ws',path=p.path or '/'}; if p.host and p.host~='' then o.transport.headers={Host=p.host} end
  elseif t=='grpc' then o.transport={type='grpc',service_name=p.serviceName or p.path or ''}
  else error('Unsupported transport: '..t) end
end
local function tls(o,p)
  local sec=p.security or p.tls
  if sec~='tls' and sec~='reality' and sec~='1' then return end
  o.tls={enabled=true,server_name=p.sni or p.serverName or o.server}
  if p.fp and p.fp~='' then o.tls.utls={enabled=true,fingerprint=p.fp} end
  if sec=='reality' then assert(p.pbk and p.pbk~='','Reality public key missing'); o.tls.reality={enabled=true,public_key=p.pbk,short_id=p.sid or ''}; o.tls.utls=o.tls.utls or {enabled=true,fingerprint='chrome'} end
  if p.alpn and p.alpn~='' then local list={}; for x in p.alpn:gmatch('[^,]+') do list[#list+1]=x end; o.tls.alpn=list end
  if p.insecure=='1' or p.allowInsecure=='1' then o.tls.insecure=true end
end
function M.parse(line)
  line=line:match('^%s*(.-)%s*$'); assert(#line>0 and #line<=8192,'Empty/long link')
  local scheme,body=line:match('^([%w]+)://(.+)$')
  if not scheme then scheme,body='sk5',line end
  scheme=scheme:lower(); local content,name=body:match('^(.-)#(.*)$'); body=content or body; name=name and decode(name)
  local o
  if scheme=='vmess' then
    local v=assert(json.parse(b64(body)),'Invalid VMess JSON')
    assert(type(v.add)=='string' and tonumber(v.port) and v.id,'Invalid VMess fields')
    o={type='vmess',server=v.add,server_port=tonumber(v.port),uuid=v.id,security=v.scy or 'auto',alter_id=tonumber(v.aid or 0)}
    transport(o,v); tls(o,{security=v.tls,sni=v.sni or v.host,fp=v.fp}); name=name or v.ps
  else
    local query; content,query=body:match('^(.-)%?(.*)$'); body=content or body
    local p={}; for k,v in (query or ''):gmatch('([^&=]+)=([^&]*)') do p[decode(k)]=decode(v) end
    body=body:gsub('/$',''); local auth,server=body:match('^(.*)@([^@]+)$')
    if scheme=='ss' and not auth then auth,server=b64(body):match('^(.*)@([^@]+)$') end
    if (scheme=='sk5' or scheme=='socks5' or scheme=='socks' or scheme=='http' or scheme=='https') and not auth then
      local host,port,user,pass=body:match('^([^:]+):(%d+):([^:]+):(.*)$')
      if host then auth,server=user..':'..pass,host..':'..port end
    end
    local host,port=endpoint(server or body)
    if scheme=='sk5' or scheme=='socks5' or scheme=='socks' or scheme=='http' or scheme=='https' then
      o={type=(scheme=='http' or scheme=='https') and 'http' or 'socks',server=host,server_port=port}
      if auth then
        if not auth:find(':',1,true) then auth=b64(auth) end
        local user,pass=auth:match('^([^:]+):(.*)$'); assert(user,'Invalid proxy credentials'); o.username,o.password=decode(user),decode(pass)
      end
      if o.type=='socks' then o.version='5'; assert(p.tls~='1','SOCKS TLS unsupported') end
      if scheme=='https' or (o.type=='http' and p.tls=='1') then o.tls={enabled=true,server_name=p.sni or host} end
    elseif scheme=='vless' then
      assert(auth,'VLESS UUID missing'); o={type='vless',server=host,server_port=port,uuid=decode(auth)}
      if p.flow and p.flow~='' then o.flow=p.flow end; transport(o,p); tls(o,p)
    elseif scheme=='trojan' then
      assert(auth,'Trojan password missing'); o={type='trojan',server=host,server_port=port,password=decode(auth)}
      p.security=p.security or 'tls'; transport(o,p); tls(o,p)
    elseif scheme=='hysteria2' or scheme=='hy2' then
      assert(auth,'Hysteria2 password missing'); o={type='hysteria2',server=host,server_port=port,password=decode(auth)}
      p.security='tls'; tls(o,p)
      if p.obfs then assert(p.obfs=='salamander' and p['obfs-password'],'Unsupported Hysteria2 obfs'); o.obfs={type='salamander',password=p['obfs-password']} end
    elseif scheme=='tuic' then
      assert(auth,'TUIC credentials missing'); local uuid,password=auth:match('^([^:]+):(.*)$'); assert(uuid,'TUIC UUID/password missing')
      o={type='tuic',server=host,server_port=port,uuid=decode(uuid),password=decode(password),congestion_control=p.congestion_control or 'cubic'}
      p.security='tls'; tls(o,p)
    elseif scheme=='ss' then
      assert(auth and not p.plugin,'SS plugins unsupported')
      if not auth:find(':',1,true) then auth=b64(auth) end
      local method,password=auth:match('^([^:]+):(.*)$'); assert(method,'SS method missing')
      o={type='shadowsocks',server=host,server_port=port,method=decode(method),password=decode(password)}
    else error('Unsupported protocol: '..scheme) end
  end
  assert(o.server_port>=1 and o.server_port<=65535,'Invalid port')
  return {name=name and name~='' and name or o.type..' '..o.server..':'..o.server_port,outbound=o,protocol=o.type=='shadowsocks' and 'ss' or o.type}
end
local function raw_batch(text)
  local nodes={}; local n=0
  for line in text:gmatch('[^\r\n]+') do
    n=n+1
    if line:match('%S') then local ok,node=pcall(M.parse,line); assert(ok,'第 '..n..' 行：'..tostring(node)); nodes[#nodes+1]=node end
    assert(#nodes<=512,'最多一次导入 512 个节点')
  end
  assert(#nodes>0,'没有有效节点'); return nodes
end
local native={socks=true,http=true,vless=true,vmess=true,trojan=true,shadowsocks=true,hysteria2=true,tuic=true}
function M.native(o,name)
  assert(type(o)=='table' and native[o.type] and type(o.server)=='string' and tonumber(o.server_port),'Unsupported native node')
  o.server_port=tonumber(o.server_port)
  assert(o.server_port>=1 and o.server_port<=65535,'Invalid node port')
  -- Remove source-specific routing references; FastACL owns routing and DNS.
  o.tag=nil; o.detour=nil; o.domain_resolver=nil
  return {name=name or o.type..' '..o.server..':'..o.server_port,protocol=o.type,outbound=o}
end
function M.clash(n)
  local t=n.type; local o={type=t=='ss' and 'shadowsocks' or t=='socks5' and 'socks' or t,server=n.server,server_port=tonumber(n.port)}
  if t=='ss' then o.method=n.cipher; o.password=n.password; assert(not n.plugin,'SS plugin unsupported')
  elseif t=='socks5' then o.version='5'; o.username=n.username; o.password=n.password
  elseif t=='http' then o.username=n.username; o.password=n.password
  elseif t=='vmess' then o.uuid=n.uuid; o.security=n.cipher or 'auto'; o.alter_id=tonumber(n.alterId or 0)
  elseif t=='vless' then o.uuid=n.uuid; o.flow=n.flow
  elseif t=='trojan' or t=='hysteria2' then o.password=n.password
  elseif t=='tuic' then o.uuid=n.uuid; o.password=n.password; o.congestion_control=n['congestion-controller'] or 'cubic'
  else error('Unsupported Clash protocol: '..tostring(t)) end
  if n.tls==true or t=='trojan' or t=='hysteria2' or t=='tuic' or n['reality-opts'] then
    o.tls={enabled=true,server_name=n.servername or n.sni or n.server,insecure=n['skip-cert-verify']==true}
    if n['client-fingerprint'] then o.tls.utls={enabled=true,fingerprint=n['client-fingerprint']} end
    local r=n['reality-opts']; if r then o.tls.reality={enabled=true,public_key=r['public-key'],short_id=r['short-id'] or ''}; o.tls.utls=o.tls.utls or {enabled=true,fingerprint='chrome'} end
    if n.alpn then o.tls.alpn=n.alpn end
  end
  if n.network then
    local opts=n['ws-opts'] or n['grpc-opts'] or {}
    transport(o,{type=n.network,path=opts.path,host=opts.headers and opts.headers.Host,serviceName=opts['grpc-service-name']})
  end
  if t=='hysteria2' and n.obfs then o.obfs={type=n.obfs,password=n['obfs-password']} end
  return M.native(o,n.name)
end
function M.subscription(text)
  assert(type(text)=='string' and #text<=2097152,'Subscription exceeds 2MB')
  text=text:gsub('^\239\187\191',''):match('^%s*(.-)%s*$')
  local nodes={}
  if text:sub(1,1)=='{' or text:sub(1,1)=='[' then
    local j=assert(json.parse(text),'Invalid subscription JSON'); local items=j.outbounds or j
    assert(type(items)=='table','No outbounds')
    for _,o in ipairs(items) do if native[o.type] then nodes[#nodes+1]=M.native(o,o.tag) end end
  elseif text:match('proxies%s*:') then
    local j=require('lyaml').load(text); assert(type(j)=='table' and type(j.proxies)=='table','Invalid Clash YAML')
    for _,n in ipairs(j.proxies) do nodes[#nodes+1]=M.clash(n) end
  else
    local first=text:match('^([^\r\n]+)') or ''
    local raw=first:match('^[%w]+://') or first:match('^[^:%s]+:%d+') or first:match('^%[[^%]]+%]:%d+')
    if not raw then text=b64(text:gsub('%s','')) end
    nodes=raw_batch(text)
  end
  assert(#nodes>0 and #nodes<=512,'Subscription must contain 1–512 supported nodes')
  return nodes
end
-- Manual import uses the same tolerant parser as subscriptions, while keeping
-- line-number diagnostics for normal multi-line links.
function M.batch(text)
  return M.subscription(text)
end
return M

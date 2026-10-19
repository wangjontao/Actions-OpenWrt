local M={}
local function enc(s) return tostring(s or ''):gsub('[^%w_.~-]',function(c) return string.format('%%%02X',c:byte()) end) end
local function object(v,label)
 if type(v)=='table' then return v end
 if type(v)=='string' and v~='' then
  local ok,t=pcall(require('luci.jsonc').parse,v)
  assert(ok and type(t)=='table',(label or 'JSON')..' must be an object')
  return t
 end
 return nil
end
local function copy(t)
 local o={}; for k,v in pairs(t or {}) do o[k]=v end; return o
end
function M.node(n)
 local raw=object(n.outbound,'Node outbound')
 local o=copy(raw or {type=n.protocol,server=n.address,server_port=tonumber(n.port),username=n.username,password=n.password})
 o.tls=object(o.tls,'TLS') or o.tls
 o.transport=object(o.transport,'Transport') or o.transport
 o.obfs=object(o.obfs,'Obfs') or o.obfs
 local allowed={type=true,server=true,server_port=true,username=true,password=true,uuid=true,security=true,alter_id=true,flow=true,method=true,version=true,tls=true,transport=true,obfs=true,congestion_control=true,tag=true}
 for k in pairs(o) do assert(allowed[k],'Unsupported dae node field: '..k) end
 local host=assert(o.server); assert(not host:find('[%s/@?#]'),'Invalid server')
 if host:find(':',1,true) then host='['..host..']' end
 local port=assert(tonumber(o.server_port));assert(port>=1 and port<=65535 and port%1==0,'Invalid port')
 local scheme,auth=o.type,'';local p={}
 if scheme=='socks' or scheme=='http' then
  if o.username then auth=enc(o.username)..':'..enc(o.password)..'@' end
  if scheme=='socks' then scheme='socks5'; assert(not o.tls or not o.tls.enabled,'SOCKS TLS unsupported')
  elseif o.tls and o.tls.enabled then scheme='https' end
 elseif scheme=='shadowsocks' then scheme='ss';auth=enc(assert(o.method))..':'..enc(assert(o.password))..'@'
 elseif scheme=='vless' then auth=enc(assert(o.uuid))..'@';p.flow=o.flow;p.type='tcp'
 elseif scheme=='trojan' or scheme=='hysteria2' then auth=enc(assert(o.password))..'@'
 elseif scheme=='tuic' then auth=enc(assert(o.uuid))..':'..enc(assert(o.password))..'@';p.congestion_control=o.congestion_control
 elseif scheme=='vmess' then
  local t=o.transport or {};local tls=o.tls or {}
  assert(not tls.reality,'VMess Reality unsupported')
  local v={v='2',ps='FastACL',add=o.server,port=tostring(port),id=assert(o.uuid),aid=tostring(o.alter_id or 0),scy=o.security or 'auto',net=t.type or 'tcp',path=t.path or t.service_name or '',host=t.headers and t.headers.Host or '',tls=tls.enabled and 'tls' or '',sni=tls.server_name,fp=tls.utls and tls.utls.fingerprint,alpn=tls.alpn and table.concat(tls.alpn,',')}
  assert(not tls.insecure,'VMess insecure setting cannot be represented safely')
  return 'vmess://'..require('nixio').bin.b64encode(require('luci.jsonc').stringify(v))
 else error('Unsupported dae protocol: '..tostring(scheme)) end
 local tls=o.tls
 if tls and tls.enabled then
  for k in pairs(tls) do assert(k=='enabled' or k=='server_name' or k=='insecure' or k=='alpn' or k=='utls' or k=='reality','Unsupported TLS field: '..k) end
  p.security='tls';p.sni=tls.server_name;p.allowInsecure=tls.insecure and '1' or nil
  if tls.alpn then p.alpn=table.concat(tls.alpn,',') end
  if tls.utls then p.fp=tls.utls.fingerprint end
  if tls.reality then p.security='reality';p.pbk=tls.reality.public_key;p.sid=tls.reality.short_id end
 end
 if o.transport then
  local t=o.transport; assert(t.type=='ws' or t.type=='grpc','Unsupported transport');p.type=t.type
  for k in pairs(t) do assert(k=='type' or k=='path' or k=='headers' or k=='service_name','Unsupported transport field') end
  if t.type=='ws' then p.path=t.path or '/';p.host=t.headers and t.headers.Host else p.serviceName=t.service_name end
 end
 if o.obfs then assert(o.type=='hysteria2' and o.obfs.type=='salamander','Unsupported obfs');p.obfs='salamander';p['obfs-password']=o.obfs.password end
 local query,keys={},{};for k,v in pairs(p) do if v~=nil and v~='' then keys[#keys+1]=k end end;table.sort(keys)
 for _,k in ipairs(keys) do query[#query+1]=enc(k)..'='..enc(p[k]) end
 return scheme..'://'..auth..host..':'..port..(#query>0 and '?'..table.concat(query,'&') or '')
end
return M

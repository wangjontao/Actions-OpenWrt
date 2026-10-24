local M={}

local providers={
  follow_exit={label='DNS 跟随代理出口（Cloudflare DoH）',scope='proxy',kind='doh',ip='1.1.1.1',name='cloudflare-dns.com',path='/dns-query'},
  baidu={label='百度 DNS',scope='direct',kind='udp',ip='180.76.76.76',port=53},
  alidns={label='阿里 DNS',scope='direct',kind='doh',ip='223.5.5.5',name='dns.alidns.com',path='/dns-query'},
  tencent={label='腾讯 DNSPod',scope='direct',kind='doh',ip='1.12.12.12',name='doh.pub',path='/dns-query'},
  public114={label='114 公共 DNS',scope='direct',kind='udp',ip='114.114.114.114',port=53},
  cnnic={label='CNNIC SDNS',scope='direct',kind='udp',ip='1.2.4.8',port=53},
  dns360={label='360 安全 DNS',scope='direct',kind='doh',ip='101.226.4.6',name='doh.360.cn',path='/dns-query'},
  cloudflare={label='Cloudflare',scope='proxy',kind='doh',ip='1.1.1.1',name='cloudflare-dns.com',path='/dns-query'},
  google={label='Google',scope='proxy',kind='doh',ip='8.8.8.8',name='dns.google',path='/dns-query'},
  opendns={label='Cisco OpenDNS',scope='proxy',kind='doh',ip='208.67.222.222',name='doh.opendns.com',path='/dns-query'},
  quad9={label='Quad9',scope='proxy',kind='doh',ip='9.9.9.9',name='dns.quad9.net',path='/dns-query'}
}

local function ip4(s)
  local a,b,c,d=tostring(s or ''):match('^(%d+)%.(%d+)%.(%d+)%.(%d+)$')
  a,b,c,d=tonumber(a),tonumber(b),tonumber(c),tonumber(d)
  return a and a<=255 and b<=255 and c<=255 and d<=255 and string.format('%d.%d.%d.%d',a,b,c,d) or nil
end

function M.catalog()
  local out={}
  for id,p in pairs(providers) do
    if id~='follow_exit' then out[#out+1]={id=id,label=p.label,scope=p.scope,kind=p.kind,ip=p.ip,name=p.name or ''} end
  end
  table.sort(out,function(a,b) if a.scope~=b.scope then return a.scope<b.scope end return a.label<b.label end)
  return out
end

-- Resolver location and egress path are independent. Proxy DNS must use DoH.
function M.allowed(id,mode)
  local p=providers[id]
  if not p then return false end
  if mode=='proxy' then return p.kind=='doh' end
  return p.scope=='direct'
end

function M.provider(id)
  local p=providers[id]
  if not p then return nil end
  return {id=id,label=p.label,scope=p.scope,kind=p.kind,ip=p.ip,name=p.name or ''}
end

function M.builtin(id)
  local p=providers[id]
  if not p then return nil end
  local r={type=p.kind,ip=p.ip,port=p.port or 443,path=p.path or '/dns-query'}
  if p.name then r.name=p.name end
  return r
end

function M.resolve(section,mode,main,resolvers,keyprefix)
  section=section or {}; main=main or {}; resolvers=resolvers or {}
  local id=section.dns or 'inherit'
  if id=='follow_exit' then assert(mode=='proxy','DNS 跟随代理出口只能用于代理设备或 WiFi') end
  if id=='' or id=='inherit' then id=(mode=='proxy' and (main.proxy_dns or 'cloudflare') or (main.direct_dns or 'alidns')) end
  if id=='custom' then
    local kind=section.dns_type or 'doh'
    assert(kind=='doh' or kind=='udp','自定义 DNS 类型必须是 DoH 或 UDP')
    local ip=assert(ip4(section.dns_ip),'自定义 DNS 需要有效 IPv4 地址')
    if mode=='proxy' and kind~='doh' then error('代理设备的自定义 DNS 必须使用 DoH，避免 DNS 直连泄漏',0) end
    local r={type=kind,ip=ip,port=kind=='udp' and 53 or 443,path='/dns-query'}
    if kind=='doh' then
      local name=tostring(section.dns_name or '')
      assert(name:match('^[%w.-]+$') and #name<=253,'自定义 DoH 需要有效域名')
      r.name=name
    end
    local key=(keyprefix or 'custom')..'_'..ip:gsub('%.','_')
    if r.name then key=key..'_'..r.name:gsub('[^%w_]','_') end
    resolvers[key]=r
    return key
  end
  local r=assert(M.builtin(id),'未知 DNS 服务商: '..tostring(id))
  if mode=='proxy' and r.type~='doh' then error('代理出口 DNS 必须使用 DoH，不能选择明文 UDP DNS',0) end
  resolvers[id]=resolvers[id] or r
  return id
end

function M.valid_id(id)
  return id=='inherit' or id=='custom' or providers[id]~=nil
end

return M

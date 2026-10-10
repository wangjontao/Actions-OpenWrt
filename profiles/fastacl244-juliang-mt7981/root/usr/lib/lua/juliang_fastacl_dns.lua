local M={}
M.providers={
 {id='alidns',name='阿里 DNS',region='domestic',server='223.5.5.5',name_tls='dns.alidns.com'},
 {id='dnspod',name='腾讯 DNSPod',region='domestic',server='1.12.12.12',name_tls='doh.pub'},
 {id='cloudflare',name='Cloudflare',region='global',server='1.1.1.1',name_tls='cloudflare-dns.com'},
 {id='google',name='Google',region='global',server='8.8.8.8',name_tls='dns.google'},
 {id='quad9',name='Quad9',region='global',server='9.9.9.9',name_tls='dns.quad9.net'},
 {id='opendns',name='OpenDNS',region='global',server='146.112.41.2',name_tls='doh.opendns.com'}
}
function M.resolve(id,url,ip)
 if id~='custom' then
  for _,p in ipairs(M.providers) do if p.id==id then return {type='https',server=p.server,server_port=443,path='/dns-query',tls={enabled=true,server_name=p.name_tls}} end end
  error('未知 DNS 服务商')
 end
 assert(type(url)=='string' and #url<=512,'自定义 DoH 地址无效')
 local host,tail=url:match('^https://([%w.-]+)(.*)$');assert(host and host:find('%.',1),'需要 HTTPS 域名')
 local port,path=tail:match('^:(%d+)(/.*)$');if not port then port=443;path=tail end
 port=tonumber(port);assert(port and port>=1 and port<=65535,'端口无效')
 if path=='' then path='/dns-query' end
 assert(path:sub(1,1)=='/' and not path:find('[%c%s#]'),'DoH 路径无效')
 local a,b,c,d=tostring(ip or ''):match('^(%d+)%.(%d+)%.(%d+)%.(%d+)$')
 assert(a and tonumber(a)<=255 and tonumber(b)<=255 and tonumber(c)<=255 and tonumber(d)<=255,'请填写服务商 IPv4 地址，避免明文域名引导解析')
 return {type='https',server=ip,server_port=port,path=path,tls={enabled=true,server_name=host}}
end
function M.get(u,scope)
 local id=u:get('juliang_fastacl','main',scope..'_dns_provider') or (scope=='domestic' and 'alidns' or 'cloudflare')
 return M.resolve(id,u:get('juliang_fastacl','main',scope..'_dns_url'),u:get('juliang_fastacl','main',scope..'_dns_ip'))
end
function M.for_node(u,node)
 if not node or node=='' then return nil end
 local id=u:get('passwall2',node,'jfa_dns_provider')
 if not id or id=='' or id=='inherit' then return nil end
 local dns=M.resolve(id,u:get('passwall2',node,'jfa_dns_url'),u:get('passwall2',node,'jfa_dns_ip'))
 return dns,u:get('passwall2',node,'jfa_dns_route')~='direct'
end
return M

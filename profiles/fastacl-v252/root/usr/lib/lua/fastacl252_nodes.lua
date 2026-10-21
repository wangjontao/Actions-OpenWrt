local M={}
local fs=require 'nixio.fs'
local json=require 'luci.jsonc'
local sys=require 'luci.sys'
local policy=require 'fastacl252'
local parser=require 'fastacl252_import'
function M.check(nodes)
  local c={network='lan',interface='br-lan',router_ip='192.168.7.1',netmask='255.255.0.0',port=12525,default_mode='direct',dns_policy='direct',dns_server='223.5.5.5',dns_name='dns.alidns.com',private_dns_server='9.9.9.9',private_dns_name='dns.quad9.net',nodes={},devices={}}
  for i,n in ipairs(nodes) do
    local id='check'..i; c.nodes[id]=n
    c.devices[#c.devices+1]={mac=string.format('02:00:00:00:%02X:%02X',math.floor(i/256),i%256),ip='192.168.'..(8+math.floor(i/254))..'.'..(i%254+1),mode='proxy',node=id}
  end
  local conf,relay=policy.compile(c)
  fs.mkdir('/tmp/fastacl252')
  fs.chmod('/tmp/fastacl252','700')
  assert(fs.writefile('/tmp/fastacl252/nodes-check.dae',conf),'Cannot stage node check')
  fs.chmod('/tmp/fastacl252/nodes-check.dae','600')
  fs.writefile('/tmp/fastacl252/nodes-dns-check.json',require('fastacl252_dae').encode_relay(relay));fs.chmod('/tmp/fastacl252/nodes-dns-check.json','600')
  local links=sys.call('fastacl252-dns -check -config /tmp/fastacl252/nodes-dns-check.json >/tmp/fastacl252/nodes-check.log 2>&1');fs.remove('/tmp/fastacl252/nodes-dns-check.json');assert(links==0,'Invalid native dae node')
  local rc=sys.call('dae validate -c /tmp/fastacl252/nodes-check.dae >/tmp/fastacl252/nodes-check.log 2>&1')
  fs.remove('/tmp/fastacl252/nodes-check.dae'); assert(rc==0,'节点包含核心不支持的参数，请检查节点格式')
end
local function hash(s)
  local h=0; for i=1,#s do h=(h*131+s:byte(i))%2147483647 end; return string.format('%08x',h)
end
function M.replace(u,nodes,owner)
  local counts,active={},{}; local bound={}
  u:foreach('fastacl252','device',function(d) bound[d.node or '']=true; bound[d.preproxy or '']=true end)
  u:foreach('fastacl252','wifi',function(w) bound[w.node or '']=true; bound[w.preproxy or '']=true end)
  for _,n in ipairs(nodes) do
    local identity=n.protocol..'\n'..n.name; counts[identity]=(counts[identity] or 0)+1
    identity=identity..'\n'..counts[identity]
    local id='n_'..hash(owner..'\n'..identity); local tries=0
    while u:get('fastacl252',id) and (u:get('fastacl252',id,'owner')~=owner or u:get('fastacl252',id,'identity')~=identity) do tries=tries+1; assert(tries<100,'Node identity collision'); id='n_'..hash(owner..'\n'..identity..'\n'..tries) end
    require('fastacl252').section(u,'fastacl252','node',id,{name=u:get('fastacl252',id,'custom_name') or n.name,protocol=n.protocol,outbound=json.stringify(n.outbound),owner=owner,identity=identity,retired='0'})
    active[id]=true
  end
  local remove={}; u:foreach('fastacl252','node',function(n)
    if n.owner==owner and not active[n['.name']] then
      if bound[n['.name']] then u:set('fastacl252',n['.name'],'retired','1') else remove[#remove+1]=n['.name'] end
    end
  end)
  for _,id in ipairs(remove) do u:delete('fastacl252',id) end
end
function M.add(u,nodes)
  local index=tonumber(u:get('fastacl252','main','import_index') or '0')+1
  M.replace(u,nodes,'manual'..index); u:set('fastacl252','main','import_index',tostring(index))
end
function M.rename(u,id,name)
  assert(policy.id(id) and u:get('fastacl252',id)=='node','节点不存在')
  assert(type(name)=='string','节点名称无效')
  name=name:gsub('^%s+',''):gsub('%s+$','')
  assert(#name>0 and #name<=240 and not name:find('[%z\1-\31\127]'),'节点名称不能为空、超过 240 字节或包含控制字符')
  assert(u:set('fastacl252',id,'name',name),'修改节点名称失败')
  assert(u:set('fastacl252',id,'custom_name',name),'保存自定义名称失败')
end
return M

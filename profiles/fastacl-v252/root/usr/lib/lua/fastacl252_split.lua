-- Destination-IP split policies. No implicit proxy-to-direct failover.
local M={}
function M.platforms(x)
 local values={};local seen={};local allowed={tiktok=true,facebook=true,instagram=true,youtube=true,shopee=true}
 local text=x.platforms or '';assert(type(text)=='string' and #text<128,'平台选项无效')
 for name in text:gmatch('[^,]+') do assert(allowed[name] and not seen[name],'平台选项无效');seen[name]=true;values[#values+1]=name end
 assert(#values==0 or x.mode=='proxy','平台强制代理需要选择出口节点');return values
end
function M.domains(x)
 M.platforms(x)
 local flag=x.dns_split or '0';assert(flag=='0' or flag=='1','Invalid DNS split flag')
 local text=x.block_domains or '';assert(type(text)=='string' and #text<=8192,'域名拦截列表过长');local out={}
 for s in (text..'\n'):gmatch('([^\n]*)\n') do s=s:match('^%s*(.-)%s*$'):lower():gsub('^%*%.',''):gsub('%.$','')
  if s~='' and s:sub(1,1)~='#' then
   assert(#s<=253 and s:find('%.') and not s:find('[^%w.%-]'),'拦截域名格式无效');for part in (s..'.'):gmatch('(.-)%.') do assert(#part>0 and #part<=63 and not part:match('^%-') and not part:match('%-$'),'拦截域名格式无效') end
   assert(not require('fastacl252').ipnum(s),'请在 IP 规则中填写 IP');out[#out+1]=s;assert(#out<=64,'最多拦截 64 个域名')
  end
 end;return out
end
function M.dns(x,p,c,resolvers)
 local selected=M.platforms(x);if #selected>0 then p.platforms=selected;p.platform_slot='platform_'..x.platform_scope end
 local blocked=M.domains(x);if #blocked>0 then p.block_domains=blocked end
 if x.mode=='proxy' and (x.split_mode or 'all')~='all' and x.dns_split=='1' then p.domestic_resolver=require('fastacl252_dns').resolve({},'direct',c,resolvers,'split_domestic') end
 return p
end
function M.parse(x)
 M.domains(x)
 local mode=x.split_mode or 'all'; assert(mode=='all' or mode=='smart' or mode=='custom','Invalid split mode')
 local text=x.split_rules or '';assert(type(text)=='string' and #text<=8192,'Split rules too long')
 local rules={}
 for line in (text..'\n'):gmatch('([^\n]*)\n') do
  line=line:match('^%s*(.-)%s*$')
  if line~='' and line:sub(1,1)~='#' then
   local action,ip,pfx=line:match('^(%a+)%s+(%d+%.%d+%.%d+%.%d+)/(%d+)$')
   if not action then action,ip=line:match('^(%a+)%s+(%d+%.%d+%.%d+%.%d+)$');pfx='32' end
   local n=require('fastacl252').ipnum(ip);pfx=tonumber(pfx)
   assert((action=='direct' or action=='proxy' or action=='block') and n and pfx and pfx>=0 and pfx<=32,'规则格式：direct/proxy/block IPv4或网段')
   assert(n%2^(32-pfx)==0,'网段必须填写网络地址')
   rules[#rules+1]={action=action,cidr=ip..'/'..pfx};assert(#rules<=64,'最多 64 条自定义规则')
  end
 end
 return mode,rules
end
function M.networks()
 local f=assert(io.open('/usr/share/fastacl252/cn-ipv4.txt'),'国内 IP 数据缺失');local out={}
 for line in f:lines() do assert(line:match('^%d+%.%d+%.%d+%.%d+/%d+$'),'国内 IP 数据损坏');out[#out+1]=line end
 f:close();assert(#out>1000,'国内 IP 数据不完整');return out
end
function M.dae(x,scope,group,rules)
 local mode,custom=M.parse(x);if mode=='all' then return end
 for _,r in ipairs(custom) do rules[#rules+1]=scope..' && dip('..r.cidr..') -> '..(r.action=='proxy' and 'must_'..group or r.action=='direct' and 'must_direct' or 'block') end
 if mode=='smart' then local nets=M.networks();for start=1,#nets,400 do local chunk={};for j=start,math.min(start+399,#nets) do chunk[#chunk+1]=nets[j] end;rules[#rules+1]=scope..' && dip('..table.concat(chunk,', ')..') -> must_direct' end end
end
function M.nft(c)
 local sets,out={},{};local cn=false
 local function one(x,scope)
  if x.mode~='proxy' then return end
  local mode,custom=M.parse(x);if mode=='all' then return end
  for _,r in ipairs(custom) do out[#out+1]=scope..'ip daddr '..r.cidr..' counter '..(r.action=='direct' and 'return' or 'drop') end
  if mode=='smart' then cn=true;out[#out+1]=scope..'ip daddr @cn_ipv4 counter return' end
 end
 for _,d in ipairs(c.devices) do one(d,'iifname "'..c.interface..'" ether saddr '..d.mac..' ip saddr '..d.ip..' ') end
 for _,w in ipairs(c.wifis or {}) do one(w,'iifname "'..w.interface..'" ip saddr '..w.subnet..' ') end
 if cn then sets[1]='set cn_ipv4 { type ipv4_addr; flags interval; auto-merge; elements = { '..table.concat(M.networks(),', ')..' }; }\n' end
 return table.concat(sets),table.concat(out,'\n')..'\n'
end
return M

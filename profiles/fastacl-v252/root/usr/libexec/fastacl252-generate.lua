local json=require 'luci.jsonc'
local policy=require 'fastacl252'
local c=require('fastacl252_env').read(nil,arg[2]=='guard')
local backend=arg[1]; assert(backend=='nft')
local rules=policy.firewall(c,backend)
local dir='/tmp/fastacl252'
local function save(name,data) local f=assert(io.open(dir..'/'..name,'w')); f:write(data); f:close() end
for k,v in pairs(rules) do save(k..'.next.rules',v) end
if arg[2]=='guard' then return end
local conf,relay=policy.compile(c)
save('router.next.dae',conf)
save('dns.next.json',require('fastacl252_dae').encode_relay(relay))

local M={}
function M.key()
 local fs=require'nixio.fs';local nx=require'nixio';local path='/etc/fastacl252-slot.key'
 local function valid(s)assert(type(s)=='string' and #s==64 and not s:find('[^0-9a-f]'),'Invalid fixed exit key');return s end
 local key=fs.readfile(path);if key then return valid(key) end
 local guard=assert(nx.open('/etc/fastacl252-slot-key.lock','w','600'));assert(guard:lock('lock'))
 local ok,result=pcall(function()
  local existing=fs.readfile(path);if existing then return valid(existing) end
  local f=assert(io.open('/dev/urandom','rb'));local bytes=f:read(32);f:close();assert(bytes and #bytes==32,'Random source unavailable')
  local generated=bytes:gsub('.',function(ch)return string.format('%02x',ch:byte())end)
  local tmp=path..'.new';assert(fs.writefile(tmp,generated));assert(fs.chmod(tmp,'600'));assert(fs.rename(tmp,path));return generated
 end)
 guard:close();assert(ok,result);return result
end
return M

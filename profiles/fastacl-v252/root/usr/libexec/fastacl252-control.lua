-- Lightweight clients for the pinned dae 2.1.1 and DNS relay control protocols.
local nx=require'nixio'
local fs=require'nixio.fs'
local function fail(message,code) io.stderr:write(message..'\n');os.exit(code or 1) end
local function dae(pid)
 pid=tonumber(pid);if not pid or pid<2 then fail('Invalid dae PID') end
 local path='/var/run/dae.progress';local previous=fs.readfile(path)
 if previous and not previous:match('^[23]') then fail('dae reload already in progress',2) end
 local pending=path..'.fastacl-new'
 if not fs.writefile(pending,'0') then fail('Cannot stage dae reload request') end
 fs.chmod(pending,'600')
 if not fs.rename(pending,path) then fs.remove(pending);fail('Cannot publish dae reload request') end
 if not nx.kill(pid,10) then
  if previous then fs.writefile(path,previous) else fs.remove(path) end
  fail('Cannot signal dae')
 end
 for _=1,600 do
  nx.nanosleep(0,100000000)
  local progress=fs.readfile(path) or ''
  local code=progress:sub(1,1)
  if code=='2' then print('OK');return end
  if code=='3' or code=='4' then fail('dae rejected reload: '..progress:sub(3),2) end
  if not nx.kill(pid,0) then fail('dae stopped during reload') end
 end
 fail('dae reload exceeded 60s safety deadline',124)
end
local function dns(file)
 if not file or file:sub(1,1)~='/' then fail('Invalid DNS configuration path') end
 local sock=assert(nx.socket('unix','stream'))
 sock:setopt('socket','sndtimeo',5);sock:setopt('socket','rcvtimeo',5)
 if not sock:connect(file..'.sock') then sock:close();fail('DNS control unavailable') end
 if sock:send('reload\n')~=7 then sock:close();fail('DNS control request failed') end
 local data=''
 while #data<8192 and not data:find('\n',1,true) do
  local chunk=sock:recv(8192-#data);if not chunk or chunk=='' then break end
  data=data..chunk
 end
 sock:close()
 local result=require('luci.jsonc').parse(data)
 if type(result)~='table' or result.ok~=true then fail('DNS reload rejected',2) end
 print('DNS configuration reloaded '..tostring(result.revision or ''))
end
if arg[1]=='dae' then dae(arg[2]) elseif arg[1]=='dns' then dns(arg[2]) else fail('Unknown control operation') end

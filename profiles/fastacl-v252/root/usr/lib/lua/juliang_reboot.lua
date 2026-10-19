local M={}
-- All effects are injected so scheduling/cancellation can be tested without rebooting.
function M.new(d)
 local fs,json=d.fs,d.json
 local dir='/tmp/juliang-reboot';local path=dir..'/state.json';local lock=dir..'.lock'
 local function read()
  local s=json.parse(fs.readfile(path) or '')
  if type(s)=='table' and type(s.id)=='string' and type(s.deadline)=='number' then return s end
 end
 local function write(s)
  assert(fs.writefile(path..'.new',json.stringify(s)),'无法保存重启计划')
  fs.chmod(path..'.new','600');assert(fs.rename(path..'.new',path),'无法更新重启计划')
 end
 local function locked(fn)
  assert(fs.mkdir(lock),'重启计划正在更新，请稍后重试');fs.chmod(lock,'700')
  local ok,result=pcall(fn);fs.rmdir(lock)
  if not ok then error(result,0) end;return result
 end
 local api={}
 function api.status()
  local s=read();if not s then return {pending=false} end
  return {pending=true,remaining=math.max(0,math.ceil(s.deadline-d.now())),executing=s.executing==true,delay=s.delay}
 end
 function api.schedule(delay)
  assert(delay==2 or delay==60,'重启延时无效')
  return locked(function()
   assert(not read(),'已有重启计划，请先取消')
   fs.mkdir(dir);fs.chmod(dir,'700')
   local id=d.token();assert(type(id)=='string' and #id==36 and id:match('^[a-f0-9%-]+$'),'无法生成重启计划标识')
   write({id=id,deadline=d.now()+delay,delay=delay})
   if not d.spawn(delay,id) then fs.remove(path);error('无法启动重启计时器',0) end
   return api.status()
  end)
 end
 function api.cancel()
  return locked(function()
   local s=read();assert(not s or not s.executing,'正在执行重启，已无法取消')
   fs.remove(path);return {pending=false}
  end)
 end
 function api.fire(id)
  return locked(function()
   local s=read()
   -- Old/cancelled workers never operate on a newer plan.
   if not s or s.id~=id or s.executing or d.now()<s.deadline then return false end
   s.executing=true;write(s)
   if not d.reboot() then fs.remove(path);error('重启命令执行失败',0) end
   return true
  end)
 end
 return api
end
function M.service()
 local fs=require'nixio.fs';local sys=require'luci.sys'
 return M.new({fs=fs,json=require'luci.jsonc',
  now=function()return assert(tonumber((fs.readfile('/proc/uptime') or ''):match('^[%d.]+')),'无法读取系统时间')end,
  token=function()return (fs.readfile('/proc/sys/kernel/random/uuid') or ''):gsub('%s','')end,
  spawn=function(delay,id)
   if not fs.access('/usr/libexec/juliang-reboot.sh') then return false end
   return sys.call('(/usr/libexec/juliang-reboot.sh '..delay..' '..id..' </dev/null >/dev/null 2>&1 &)')==0
  end,
  reboot=function()return sys.call('/sbin/reboot')==0 end})
end
return M

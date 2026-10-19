module('luci.controller.juliang_center',package.seeall)
function index()
  local p=entry({'admin','juliang'},firstchild(),_('JuLiang 控制中心'),1); p.dependent=false; p.acl_depends={'juliang-center'}
  local h=entry({'admin','juliang','home'},template('juliang_center/home'),_('控制中心'),1); h.leaf=true; h.acl_depends={'juliang-center'}
  local w=entry({'admin','juliang','wireless'},template('juliang_center/wireless'),_('无线设备'),2); w.leaf=true; w.acl_depends={'juliang-center'}
  local a=entry({'admin','juliang','status'},call('status'),nil); a.leaf=true; a.acl_depends={'juliang-center'}
  local r=entry({'admin','juliang','reboot'},post('reboot_action'),nil);r.leaf=true;r.acl_depends={'juliang-center'}
end
local function reply(t)
  local h=require 'luci.http'; h.prepare_content('application/json'); h.write(require('luci.jsonc').stringify(t))
end
function can_reboot()
  local sid=require('luci.dispatcher').context.authsession
  if not sid then return false end
  local ok,r=pcall(require('luci.util').ubus,'session','access',{ubus_rpc_session=sid,scope='ubus',object='system',['function']='reboot'})
  return ok and type(r)=='table' and r.access==true
end
function can_autoreboot()
  local sid=require('luci.dispatcher').context.authsession
  if not sid then return false end
  local ok,r=pcall(require('luci.util').ubus,'session','access',{ubus_rpc_session=sid,scope='uci',object='autoreboot',['function']='write'})
  return ok and type(r)=='table' and r.access==true
end
function reboot_action()
  local h=require'luci.http'
  if not can_reboot() then h.status(403,'Forbidden');reply({ok=false,error='当前帐号没有重启权限'});return end
  local ok,result=pcall(function()
    local scheduler=require('juliang_reboot').service();local action=h.formvalue('action')
    if action=='now' then return scheduler.schedule(2)
    elseif action=='delay' then return scheduler.schedule(60)
    elseif action=='cancel' then return scheduler.cancel()
    else error('重启操作无效',0) end
  end)
  if ok then reply({ok=true,reboot=result}) else reply({ok=false,error=tostring(result)}) end
end
local function wired_ports()
  local fs=require'nixio.fs';local json=require'luci.jsonc'
  local board=json.parse(fs.readfile('/etc/board.json') or '') or {};local rows={};local seen={}
  local function add(dev,role)
    if type(dev)~='string' or not dev:match('^[%w_.%-]+$') or seen[dev] then return end
    seen[dev]=true;local base='/sys/class/net/'..dev..'/'
    local carrier=tonumber(fs.readfile(base..'carrier') or '')
    local speed=tonumber(fs.readfile(base..'speed') or '')
    local duplex=(fs.readfile(base..'duplex') or ''):match('%S+')
    rows[#rows+1]={device=dev,role=role,connected=carrier==1,known=carrier~=nil,speed=carrier==1 and speed and speed>0 and speed or nil,duplex=duplex}
  end
  for _,role in ipairs({'wan','lan'}) do
    local net=(board.network or {})[role] or {}
    if type(net.ports)=='table' then for _,dev in ipairs(net.ports) do add(dev,role) end else add(net.device,role) end
  end
  return rows
end
function status()
  local json=require 'luci.jsonc'; local sys=require 'luci.sys'; local u=require('uci').cursor()
  local wan=json.parse(sys.exec('ubus call network.interface.wan status 2>/dev/null')) or {}
  local ip=''; for _,a in ipairs(wan['ipv4-address'] or {}) do if a.address then ip=a.address break end end
  local wifi=0; u:foreach('wireless','wifi-iface',function(s) if s.disabled~='1' then wifi=wifi+1 end end)
  local managed=0; u:foreach('fastacl252','wifi',function() managed=managed+1 end)
  local fast=json.parse(sys.exec('/usr/bin/fastacl252 status 2>/dev/null')) or {}
  local up=tonumber(sys.exec("cut -d. -f1 /proc/uptime 2>/dev/null") or '0') or 0
  local dev=wan.l3_device or wan.device or '';local counters={}
  if dev:match('^[%w_.%-]+$') then
    local fs=require'nixio.fs'
    counters.rx_bytes=tonumber(fs.readfile('/sys/class/net/'..dev..'/statistics/rx_bytes') or '')
    counters.tx_bytes=tonumber(fs.readfile('/sys/class/net/'..dev..'/statistics/tx_bytes') or '')
  end
  counters.timestamp=tonumber(sys.exec('cat /proc/uptime'):match('^[%d.]+')) or up
  counters.device=dev
  reply({ok=true,reboot=can_reboot() and require('juliang_reboot').service().status() or nil,ports=wired_ports(),traffic=counters,hostname=sys.hostname() or 'JuLiangTK-S20L',uptime=up,wan_up=wan.up==true,wan_ip=ip,wan_device=wan.l3_device or wan.device or '',wifi_count=wifi,managed_wifi=managed,fastacl=fast,version='FastACL 2.5.5 dae/eBPF'})
end

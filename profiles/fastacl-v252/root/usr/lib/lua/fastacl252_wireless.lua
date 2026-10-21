-- Read-only per-SSID station telemetry. Never returns wireless keys.
local M={}
function M.parse(text)
 local out,row={}
 for line in tostring(text or ''):gmatch('[^\n]+') do
  local mac=line:match('^Station%s+([%x:]+)')
  if mac then row={mac=mac:upper()};out[#out+1]=row
  elseif row then
   local key,value=line:match('^%s*([^:]+):%s*(.*)')
   if key=='rx bytes' then row.rx_bytes=tonumber(value)
   elseif key=='tx bytes' then row.tx_bytes=tonumber(value)
   elseif key=='signal' then row.signal=tonumber(value:match('^(-?%d+)'))
   elseif key=='tx bitrate' then row.tx_link_mbps=tonumber(value:match('([%d.]+)%s+MBit/s'))
   elseif key=='rx bitrate' then row.rx_link_mbps=tonumber(value:match('([%d.]+)%s+MBit/s'))
   elseif key=='connected time' then row.connected_seconds=tonumber(value:match('^(%d+)'))
   end
  end
 end
 return out
end
function M.read()
 local sys=require'luci.sys';local json=require'luci.jsonc';local u=require('uci').cursor();local rows={};local names={};local ips={}
 local f=io.open('/tmp/dhcp.leases');if f then for line in f:lines() do local mac,ip,name=line:match('^%d+%s+(%S+)%s+(%S+)%s+(%S+)');if mac then names[mac:upper()]=name~='*' and name or '' end end;f:close() end
 u:foreach('fastacl252','device',function(d)if d.mac and d.name and d.name~='' then names[d.mac:upper()]=d.name end end)
 for line in sys.exec('ip -4 neigh show 2>/dev/null'):gmatch('[^\n]+') do local ip,dev,mac=line:match('^(%S+)%s+dev%s+(%S+).-lladdr%s+(%S+)');if mac then ips[dev..'/'..mac:upper()]=ip end end
 local status=json.parse(sys.exec('ubus call network.wireless status 2>/dev/null')) or {}
 for radio,info in pairs(status) do
  for _,iface in ipairs(info.interfaces or {}) do
   local dev=iface.ifname;local cfg=iface.config or {}
   if type(dev)=='string' and dev:match('^[%w_.%-]+$') and (cfg.mode=='ap' or cfg.mode==nil) then
    local net=cfg.network;if type(net)=='table' then net=net[1] end
    local bridge=net and u:get('network',net,'device') or ''
    local stations=M.parse(sys.exec('iw dev '..dev..' station dump 2>/dev/null'))
    for _,s in ipairs(stations) do s.name=names[s.mac] or '';s.ip=ips[(bridge or '')..'/'..s.mac] or '' end
    rows[#rows+1]={id=dev,ssid=cfg.ssid or u:get('wireless',iface.section or '','ssid') or dev,radio=radio,network=net or '',stations=stations,up=info.up==true}
   end
  end
 end
 table.sort(rows,function(a,b)return a.ssid<b.ssid end)
 local uptime=tonumber(sys.exec('cat /proc/uptime'):match('^[%d.]+')) or os.time()
 return {ok=true,interfaces=rows,timestamp=uptime,interval=3}
end
return M

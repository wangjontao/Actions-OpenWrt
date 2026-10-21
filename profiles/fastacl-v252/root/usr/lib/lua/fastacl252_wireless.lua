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
-- MTWiFi exposes stations through iwinfo and byte counters through its vendor ioctl.
-- Its association table can contain other BSSes: only accept the bridge FDB owner.
function M.parse_mtwifi(text)
 local rows,row={}
 for line in tostring(text or ''):gmatch('[^\n]+') do
  local mac,signal=line:match('^([%x:]+)%s+([%-0-9]+)%s+dBm')
  if mac then row={mac=mac:upper(),signal=tonumber(signal)};rows[#rows+1]=row
  elseif row then
   local kind,value=line:match('^%s*(R[X]):%s*([%d.]+)%s+MBit/s')
   if kind then row.rx_link_mbps=tonumber(value) end
   kind,value=line:match('^%s*(T[X]):%s*([%d.]+)%s+MBit/s')
   if kind then row.tx_link_mbps=tonumber(value) end
  end
 end
 return rows
end
function M.read_mtwifi(dev,sys,json)
 if not (dev:match('^ra%d+$') or dev:match('^rax%d+$')) then return {} end
 local fdb=json.parse(sys.exec('bridge -j fdb show dev '..dev..' 2>/dev/null')) or {}
 local owned={}
 for _,e in ipairs(fdb) do
  -- bridge fdb show dev already scopes rows; some iproute2 builds omit owner.
  local owner=e.dev or e.ifname
  if (owner==nil or owner==dev) and type(e.mac)=='string' then owned[e.mac:upper()]=true end
 end
 local rows,args={},{}
 for _,entry in ipairs(M.parse_mtwifi(sys.exec('iwinfo '..dev..' assoclist 2>/dev/null'))) do
  if owned[entry.mac] and entry.mac:match('^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$') then
   rows[#rows+1]=entry;args[#args+1]=dev;args[#args+1]=entry.mac
  end
 end
 local bytes=#args>0 and json.parse(sys.exec('/usr/libexec/mtwifi-station-bytes '..table.concat(args,' ')..' 2>/dev/null')) or {}
 for _,entry in ipairs(rows) do
  local stat=bytes[dev..'/'..entry.mac]
  if type(stat)=='table' and type(stat.rx_bytes)=='number' and type(stat.tx_bytes)=='number' then
   entry.rx_bytes=stat.rx_bytes;entry.tx_bytes=stat.tx_bytes
  end
 end
 return rows
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
    local mtwifi=u:get('wireless',radio,'type')=='mtwifi'
    local stations=mtwifi and M.read_mtwifi(dev,sys,json) or M.parse(sys.exec('iw dev '..dev..' station dump 2>/dev/null'))
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

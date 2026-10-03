#!/usr/bin/lua

local jsonc=require "luci.jsonc"
local sys=require "luci.sys"
local uci=require("luci.model.uci").cursor()

local TOPO="/etc/fastc/topology.json"
local SUBNETS="/etc/fastc/subnets.list"

local function split_words(v)
  local out={}
  if type(v)=="table" then
    for _,x in ipairs(v) do if x and x~="" then out[#out+1]=x end end
  elseif type(v)=="string" then
    for x in v:gmatch("%S+") do out[#out+1]=x end
  end
  return out
end
local function ip_to_num(ip)
  local a,b,c,d=tostring(ip or ""):match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
  a,b,c,d=tonumber(a),tonumber(b),tonumber(c),tonumber(d)
  if not a or a>255 or b>255 or c>255 or d>255 then return nil end
  return ((a*256+b)*256+c)*256+d
end
local function num_to_ip(n)
  return string.format("%d.%d.%d.%d",math.floor(n/16777216)%256,math.floor(n/65536)%256,math.floor(n/256)%256,n%256)
end
local function mask_to_prefix(mask)
  if not mask or mask=="" then return 24 end
  local p=tonumber(mask); if p and p>=0 and p<=32 then return p end
  local n=ip_to_num(mask); if not n then return nil end
  local bits,seen_zero=0,false
  for i=31,0,-1 do
    local bit=math.floor(n/(2^i))%2
    if bit==1 then if seen_zero then return nil end; bits=bits+1 else seen_zero=true end
  end
  return bits
end
local function cidr_from(ip,mask)
  if not ip or ip=="" then return nil end
  local bare,slash=tostring(ip):match("^([^/]+)/(%d+)$")
  if bare then ip=bare; mask=slash end
  local n,p=ip_to_num(ip),mask_to_prefix(mask)
  if not n or not p then return nil end
  local block=2^(32-p)
  return num_to_ip(math.floor(n/block)*block).."/"..tostring(p)
end
local function shell_quote(s) return "'"..tostring(s or ""):gsub("'","'\\''").."'" end
local function network_ipv4(net)
  local ip=uci:get("network",net,"ipaddr")
  local mask=uci:get("network",net,"netmask")
  if type(ip)=="table" then ip=ip[1] end
  local cidr=cidr_from(ip,mask)
  if cidr then return cidr,tostring(ip):match("^([^/]+)") end
  local raw=sys.exec("ubus call network.interface."..shell_quote(net).." status 2>/dev/null") or ""
  local ok,st=pcall(jsonc.parse,raw)
  if ok and type(st)=="table" and type(st["ipv4-address"])=="table" then
    local a=st["ipv4-address"][1]
    if a and a.address and a.mask then return cidr_from(a.address,a.mask),a.address end
  end
  return nil
end
local function read_json(path)
  local f=io.open(path,"rb"); if not f then return nil end
  local raw=f:read("*a") or ""; f:close()
  local ok,obj=pcall(jsonc.parse,raw); if ok and type(obj)=="table" then return obj end
  return nil
end
local function write_file(path,data)
  local f=assert(io.open(path,"wb")); f:write(data); f:close()
end

local lan_cidr=nil
do
  local ip=uci:get("network","lan","ipaddr")
  local mask=uci:get("network","lan","netmask")
  if type(ip)=="table" then ip=ip[1] end
  lan_cidr=cidr_from(ip,mask)
end

local include_lan=(uci:get("juliang_fastacl","main","include_lan") or uci:get("fastc","main","include_lan") or "1")~="0"
local ignore={wan=true,wan6=true,loopback=true,wwan=true}
local by_net={}

uci:foreach("wireless","wifi-iface",function(s)
  if tostring(s.disabled or "0")~="1" and tostring(s.mode or "ap")=="ap" then
    local ssid=s.ssid or s[".name"] or "WiFi"
    for _,net in ipairs(split_words(s.network)) do
      if not ignore[net] and (net~="lan" or include_lan) then
        local cidr,router_ip=network_ipv4(net)
        if cidr and (net=="lan" or cidr~=lan_cidr) then
          local item=by_net[net]
          if not item then
            item={network=net,subnet=cidr,router_ip=router_ip or "",ssids={},is_lan=(net=="lan")}
            by_net[net]=item
          end
          local found=false
          for _,v in ipairs(item.ssids) do if v==ssid then found=true break end end
          if not found then item.ssids[#item.ssids+1]=ssid end
        end
      end
    end
  end
end)

if include_lan and lan_cidr and not by_net.lan then
  local cidr,router_ip=network_ipv4("lan")
  if cidr then by_net.lan={network="lan",subnet=cidr,router_ip=router_ip or "",ssids={},is_lan=true} end
end

local items={}
for _,item in pairs(by_net) do
  table.sort(item.ssids)
  if item.is_lan then
    local wifi=table.concat(item.ssids," / ")
    item.ssid=(wifi~="" and ("主网络 · "..wifi.." · 有线LAN") or "主网络 · 有线LAN")
    item._main_lan=true
  else
    item.ssid=table.concat(item.ssids," / ")
    item._main_lan=false
  end
  item._sort=ip_to_num((item.subnet or ""):match("^([^/]+)/")) or 0
  items[#items+1]=item
end

table.sort(items,function(a,b)
  if a._main_lan~=b._main_lan then return not a._main_lan end
  if a._sort==b._sort then return a.network<b.network end
  return a._sort<b._sort
end)

if #items==0 then
  local old=read_json(TOPO)
  if old and type(old.aps)=="table" and #old.aps>0 then
    old.preserved=true; old.error="NO_AP_READY"
    io.write(jsonc.stringify(old,true),"\n")
    os.exit(2)
  end
  io.write(jsonc.stringify({ok=false,count=0,aps={},preserved=false,error="NO_AP_READY"},true),"\n")
  os.exit(2)
end

local aps={}
local subnets={}
for i,item in ipairs(items) do
  aps[#aps+1]={
    slot=i,
    group="A"..i,
    network=item.network,
    ssid=item.ssid~="" and item.ssid or ("A"..i),
    subnet=item.subnet,
    router_ip=item.router_ip or "",
    is_lan=item.is_lan and true or false
  }
  subnets[#subnets+1]=item.subnet
end

os.execute("mkdir -p /etc/fastc")
local obj={ok=true,count=#aps,aps=aps,updated=os.time()}
write_file(TOPO,jsonc.stringify(obj,true).."\n")
write_file(SUBNETS,table.concat(subnets,"\n").."\n")
io.write(jsonc.stringify(obj,true),"\n")

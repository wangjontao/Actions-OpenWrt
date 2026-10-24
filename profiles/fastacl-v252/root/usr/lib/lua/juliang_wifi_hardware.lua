-- MT7981/MT7986 EEPROM MAC source. Never use a reference profile as identity.
local M={}
local function valid(b)
  if not b or #b~=6 or b[1]%2~=0 then return false end
  local sum=0; for _,v in ipairs(b) do sum=sum+v end
  return sum>0 and sum<1530 and not (b[2]==0xca and b[3]==0x81)
end
local function text(b)
  return string.format('%02x:%02x:%02x:%02x:%02x:%02x',unpack(b))
end
function M.read()
  local p=assert(io.open('/proc/mtd','r'),'Cannot read MTD map')
  local map=p:read('*a'); p:close()
  local id=map:match('(mtd%d+):[^\n]-"Factory"')
  assert(id,'Factory partition missing; refusing reference MAC fallback')
  local f=assert(io.open('/dev/'..id,'rb'),'Cannot read Factory EEPROM')
  local data=f:read(16); f:close()
  assert(data and #data>=16,'Factory EEPROM too short')
  local magic=data:byte(1)+256*data:byte(2)
  assert(magic==0x7981 or magic==0x7986,'Unsupported EEPROM layout; no MAC changes made')
  local a={data:byte(5,10)}; local b={data:byte(11,16)}
  assert(valid(a) and valid(b) and text(a)~=text(b),'Invalid Factory radio MACs')
  return {['2g']=text(a),['5g']=text(b)}
end
function M.apply(cfg,dats)
  local band=cfg.config and cfg.config.band
  if band~='2g' and band~='5g' then error('Unknown radio band; refusing reference MAC',0) end
  -- The proprietary DBDC driver derives its automatic BSSIDs from this base.
  -- Set it on every setup, including when the first SSID has been deleted.
  dats.MacAddress=M.read()[band]
end
function M.preflight()
  local f=io.open('/sbin/mtwifi_cfg','r')
  if not f then return end -- Native mac80211 uses its own EEPROM/PHY identity.
  f:close(); return M.read()
end
return M

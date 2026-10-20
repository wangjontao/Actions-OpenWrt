-- First-boot MT7981 performance adjustments for the pinned MTWiFi stack.
local fs=require('nixio.fs')
local root='/usr/share/fastacl252/mt7981-performance/'
local function install(src,dst)
 local data=assert(fs.readfile(root..src),'Missing MT7981 performance payload: '..src)
 assert(fs.writefile(dst..'.juliang-new',data));assert(fs.chmod(dst..'.juliang-new','755'));assert(fs.rename(dst..'.juliang-new',dst))
end
if fs.access('/usr/sbin/wrtbwmon') then
 install('wrtbwmon.init','/etc/init.d/wrtbwmon')
 install('99-wrtbwmon','/etc/hotplug.d/iface/99-wrtbwmon')
end
local path='/sbin/mtwifi_cfg';local text=fs.readfile(path)
if text and not text:find('-- JuLiang: keep allocated AP slots',1,true) then
 local needle='    if bssid_num > 0 then\n        dats.BssidNum = bssid_num'
 local replacement='    -- JuLiang: keep allocated AP slots instead of unloading the driver on delete.\n    local allocated_bssids = math.min(tonumber(dats_orig.BssidNum) or 1, defs.max_mbssid)\n    bssid_num = math.max(bssid_num, allocated_bssids)\n\n'..needle
 local pattern=needle:gsub('(%W)','%%%1');local updated,n=text:gsub(pattern,function() return replacement end,1)
 assert(n==1,'Unsupported mtwifi-cfg version: AP allocation block not found')
 local validate=updated:gsub('^#![^\n]*\n','',1);assert(loadstring(validate))
 assert(fs.writefile(path..'.juliang-new',updated));assert(fs.chmod(path..'.juliang-new','755'));assert(fs.rename(path..'.juliang-new',path))
end

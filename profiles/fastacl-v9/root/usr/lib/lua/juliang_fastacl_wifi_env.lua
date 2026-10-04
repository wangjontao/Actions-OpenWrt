local M={}
local sys=require "luci.sys"
local fs=require "nixio.fs"
local util=require "luci.util"
local json=require "luci.jsonc"
local model=require "juliang_fastacl_wifi"
function M.revision()
    local out=sys.exec("sha256sum /etc/config/wireless /etc/config/network /etc/config/dhcp /etc/config/firewall /etc/config/juliang_fastacl /etc/config/passwall2 2>/dev/null") or ""
    return out
end
function M.capacity(s)
    local phy=s.phy
    if not phy or not phy:match("^phy%d+$") then
        local raw=sys.exec("ubus call network.wireless status 2>/dev/null")
        local st=json.parse(raw or "") or {}; local r=st[s[".name"]] or {}
        for _,it in ipairs(r.interfaces or {}) do
            if tostring(it.ifname or ""):match("^[%w_.%-]+$") then
                local n=(sys.exec("iw dev "..util.shellquote(it.ifname).." info 2>/dev/null") or ""):match("wiphy%s+(%d+)")
                if n then phy="phy"..n; break end
            end
        end
    end
    if phy and phy:match("^phy%d+$") then
        local raw=sys.exec("iw phy "..phy.." info 2>/dev/null") or ""
        local part=raw:match("valid interface combinations:(.*)") or ""
        local cap
        for combo in part:gmatch("%*([^%*]+)") do
            local ap,total
            for types,n in combo:gmatch("#{%s*([^}]+)%s*}%s*<=%s*(%d+)") do
                for t in types:gmatch("[^,]+") do if t:match("^%s*AP%s*$") then ap=tonumber(n) end end
            end
            total=tonumber(combo:match("total%s*<=%s*(%d+)"))
            if ap then local limit=math.min(ap,total or ap);cap=math.max(cap or 0,limit) end
        end
        if cap then return math.min(cap,16),true end
    end
    -- Conservative fallback when the proprietary driver has no nl80211 limits.
    return 8,false
end
function M.routes()
    local rows={}
    for line in (sys.exec("ip -4 route show table all 2>/dev/null") or ""):gmatch("[^\r\n]+") do
        local cidr=line:match("^(%d+%.%d+%.%d+%.%d+/%d+)") or line:match("^%S+%s+(%d+%.%d+%.%d+%.%d+/%d+)")
        if cidr and not cidr:match("/0$") then local r=model.range(cidr,32);if r then rows[#rows+1]=r end end
    end
    return rows
end
function M.pending(u)
    for _,cfg in ipairs(model.configs) do
        local changes=u:changes(cfg)
        if type(changes)=="table" and next(changes) then return true end
    end
    return false
end
function M.status(u)
    local nodes={}
    u:foreach("passwall2","nodes",function(s)
        if tostring(s.protocol or ""):sub(1,1)~="_" then nodes[#nodes+1]={id=s[".name"],name=s.remarks or s[".name"]} end
    end)
    table.sort(nodes,function(a,b)return a.name<b.name end)
    local mode=u:get("juliang_fastacl","main","runtime_mode") or "fastacl"
    return {ok=true,radios=model.radios(u,M),managed=model.managed(u),nodes=nodes,mode=mode,pending=M.pending(u)}
end
function M.call(cmd)
    if sys.call(cmd.." >/dev/null 2>&1")~=0 then error("应用失败："..cmd,0) end
end
return M

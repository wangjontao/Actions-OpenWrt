local fs=require "nixio.fs"
local sys=require "luci.sys"
local json=require "luci.jsonc"
local util=require "luci.util"
local model=require "juliang_fastacl_wifi"
local env=require "juliang_fastacl_wifi_env"
local id=arg[1] or ""
assert(id:match("^%d+%-%d+%-%d+$"),"Invalid job")
local dir="/tmp/juliang-fastacl-wifi/"
local jobfile=dir..id..".json"
local req=json.parse(fs.readfile(dir..id..".request") or "")
fs.remove(dir..id..".request")
local u=require("luci.model.uci").cursor()
local backup="/etc/juliang-fastacl/wifi-backups/"..id
local mode=u:get("juliang_fastacl","main","runtime_mode") or "fastacl"
local enabled=u:get("juliang_fastacl","main","enabled") or "1"
local locked,modified=false,false
local function result(v)
    fs.writefile(jobfile..".tmp",json.stringify(v));fs.rename(jobfile..".tmp",jobfile)
end
local function reload()
    env.call("/etc/init.d/network reload")
    env.call("/etc/init.d/firewall restart")
    env.call("/etc/init.d/dnsmasq restart")
    env.call("wifi reload")
end
local function verify(plan)
    local expected={}
    u:foreach("wireless","wifi-iface",function(s)
        if tostring(s.disabled or "0")~="1" and (s.mode or "ap")=="ap" and tostring(u:get("wireless",s.device,"disabled") or "0")~="1" then
            expected[s[".name"]]={ssid=s.ssid,device=s.device}
        end
    end)
    for _=1,60 do
        local st=json.parse(sys.exec("ubus call network.wireless status 2>/dev/null") or "") or {}
        local found={}
        for device,r in pairs(st) do
            if type(r)=="table" and r.up==true then
                for _,it in ipairs(r.interfaces or {}) do
                    local e=expected[it.section]
                    if e and e.device==device and (it.config or {}).ssid==e.ssid and fs.access("/sys/class/net/"..tostring(it.ifname or "").."/operstate") then found[it.section]=true end
                end
            end
        end
        local ready=true
        for section in pairs(expected) do if not found[section] then ready=false end end
        for _,row in ipairs(plan.rows) do
            local present=fs.access("/sys/class/net/br-"..row.network)
            if plan.action=="create" then
                if not present then ready=false end
                local net=json.parse(sys.exec("ubus call network.interface."..row.network.." status 2>/dev/null") or "") or {}
                local matched=false
                for _,addr in ipairs(net["ipv4-address"] or {}) do if addr.address==row.ip then matched=true end end
                if net.up~=true or not matched then ready=false end
            elseif present then ready=false end
        end
        if ready then return end
        require("nixio").nanosleep(1)
    end
    error("无线或独立网段未正常启动，已尝试恢复原配置",0)
end
local ok,err=pcall(function()
    assert(type(req)=="table","请求已失效")
    if not fs.mkdir("/tmp/juliang-fastacl-runtime.lock","700") then error("运行模式正在切换，请稍后重试",0) end
    locked=true
    if env.pending(u) then error("存在未提交配置，请先保存或撤销",0) end
    local plan=model.plan(u,req,env)
    if req.revision~=plan.revision then error("配置已经变化，请重新预览",0) end
    result({ok=true,state="applying",message="正在建立配置并检查无线，可能短暂断开，请稍后刷新",count=#plan.rows})
    assert(fs.mkdirr(backup),"无法建立配置备份")
    fs.chmod(backup,"700")
    for _,cfg in ipairs(model.configs) do
        assert(fs.copy("/etc/config/"..cfg,backup.."/"..cfg),"备份失败")
        fs.chmod(backup.."/"..cfg,"600")
    end
    -- Validate all changes before stopping the current dataplane.
    model.mutate(u,plan,req)
    modified=true
    env.call("/etc/init.d/juliang-fastacl stop")
    for _,cfg in ipairs(model.configs) do assert(u:commit(cfg),"配置提交失败") end
    -- Slot numbers may change: discard only our generated forwards before rebuilding.
    local forwards={}
    u:foreach("firewall","forwarding",function(s)
        if s[".name"]:match("^jfa_direct_ap%d+$") or s[".name"]:match("^jfa_runtime_ap%d+$") then forwards[#forwards+1]=s[".name"] end
    end)
    for _,name in ipairs(forwards) do u:delete("firewall",name) end
    assert(u:commit("firewall"),"转发规则提交失败")
    -- All AP slots are rediscovered atomically; old bindings/modes are preserved.
    env.call("lua /usr/libexec/juliang-fastacl-discover.lua")
    u=require("luci.model.uci").cursor()
    model.bind(u,plan)
    assert(u:commit("juliang_fastacl"),"节点绑定提交失败")
    reload()
    if mode=="normal_proxy" or enabled=="1" then
        env.call("/usr/bin/juliang-fastacl-runtime _apply "..mode)
    end
    verify(plan)
    -- Keep the persistent good-state snapshot synchronized with the topology.
    if mode=="fastacl" and enabled=="1" then env.call("/usr/bin/juliang-fastacl save-state") end
    result({ok=true,state="done",message=plan.action=="create" and "批量无线已建立并通过启动检查" or "批量无线已清除",count=#plan.rows,backup=backup})
end)
if not ok then
    local restored=true
    for _,cfg in ipairs(model.configs) do u:revert(cfg) end
    if modified then
        sys.call("/etc/init.d/juliang-fastacl stop >/dev/null 2>&1")
        for _,cfg in ipairs(model.configs) do if not fs.copy(backup.."/"..cfg,"/etc/config/"..cfg) then restored=false end end
        for _,cmd in ipairs({"/etc/init.d/network reload","/etc/init.d/firewall restart","/etc/init.d/dnsmasq restart","wifi reload"}) do
            if sys.call(cmd.." >/dev/null 2>&1")~=0 then restored=false end
        end
        if mode=="normal_proxy" or enabled=="1" then
            if sys.call("/usr/bin/juliang-fastacl-runtime _apply "..mode.." >/dev/null 2>&1")~=0 then restored=false end
        end
    end
    result({ok=false,state="failed",error=tostring(err),rolled_back=modified and restored,rollback_failed=modified and not restored,backup=modified and backup or nil})
end
if locked then fs.rmdir("/tmp/juliang-fastacl-runtime.lock") end
fs.rmdir("/tmp/juliang-fastacl-wifi.lock")

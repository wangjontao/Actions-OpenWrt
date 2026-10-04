-- FastACL batch WiFi: tagged ownership, validated preview, transactional apply.
local M = {}
local OWNER = "fastacl-batch-v1"
local CONFIGS = {"wireless", "network", "dhcp", "firewall", "juliang_fastacl"}
local function fail(s) error(s, 0) end
local function words(v)
    if type(v) == "table" then return v end
    local a = {}; for x in tostring(v or ""):gmatch("%S+") do a[#a+1] = x end; return a
end
local function integer(v, lo, hi, msg)
    local n = tonumber(v)
    if not n or n ~= math.floor(n) or n < lo or n > hi then fail(msg) end
    return n
end
local function ipnum(ip)
    local a,b,c,d = tostring(ip or ""):match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
    a,b,c,d = tonumber(a),tonumber(b),tonumber(c),tonumber(d)
    if not a or a>255 or b>255 or c>255 or d>255 then return nil end
    return ((a*256+b)*256+c)*256+d
end
local function range(ip, mask)
    local bare, p = tostring(ip or ""):match("^([^/]+)/(%d+)$")
    if bare then ip, mask = bare, p end
    local n, bits = ipnum(ip), tonumber(mask)
    if not bits then
        local m = ipnum(mask or "255.255.255.0")
        if not m then return nil end
        bits = 0; local zero = false
        for i=31,0,-1 do
            if math.floor(m/2^i)%2 == 1 then
                if zero then return nil end; bits=bits+1
            else zero=true end
        end
    end
    if not n or bits<0 or bits>32 then return nil end
    local size=2^(32-bits); local start=math.floor(n/size)*size
    return {start, start+size-1}
end
local function section_owned(s) return s and s.jfa_owner == OWNER end
function M.managed(u)
    local a={}
    u:foreach("wireless", "wifi-iface", function(s)
        if section_owned(s) then
            a[#a+1]={section=s[".name"],ssid=s.ssid or "",device=s.device or "",network=s.jfa_network or ""}
        end
    end)
    table.sort(a,function(x,y) return x.section<y.section end)
    return a
end
function M.radios(u, env)
    local a={}
    u:foreach("wireless", "wifi-device", function(s)
        local band=s.band or (s.hwmode=="11g" and "2g" or s.hwmode=="11a" and "5g" or "")
        local used=0
        u:foreach("wireless", "wifi-iface",function(w) if w.device==s[".name"] then used=used+1 end end)
        local cap, verified=env.capacity(s)
        a[#a+1]={id=s[".name"],band=band,used=used,limit=cap,available=math.max(0,cap-used),verified=verified}
    end)
    table.sort(a,function(x,y) return x.id<y.id end)
    return a
end
function M.plan(u, req, env)
    local action=req.action
    if action=="clear" then
        local rows=M.managed(u)
        if #rows==0 then fail("没有通过批量功能建立的无线") end
        local nets={}
        for _,row in ipairs(rows) do
            if not row.network:match("^jfaw%d+$") or not section_owned(u:get_all("network",row.network)) then
                fail("批量无线的归属标记不完整，请先检查："..row.ssid)
            end
            nets[row.network]=true
        end
        -- Do not remove a network reused by a manually created wireless.
        u:foreach("wireless","wifi-iface",function(s)
            for _,net in ipairs(words(s.network)) do
                if nets[net] and not section_owned(s) then fail("网段已被其他无线使用，无法清除："..net) end
            end
        end)
        return {action=action,rows=rows,revision=env.revision()}
    end
    if action~="create" then fail("不支持的操作") end
    local prefix=tostring(req.prefix or "")
    if prefix=="" or prefix:find("[%z\1-\31\127]") then fail("请输入有效的无线名称前缀") end
    local key=tostring(req.key or "")
    if #key<8 or #key>63 or key:find("[^ -~]") then fail("密码需要 8～63 个 ASCII 可打印字符") end
    local start=integer(req.start or 1,1,9999,"起始编号需为 1～9999")
    local counts=req.counts or {}; if type(counts)~="table" then fail("无线数量格式错误") end
    local radios=M.radios(u,env); local total=0; local selected={}
    for _,r in ipairs(radios) do
        local n=integer(counts[r.id] or 0,0,20,"每个频段的新增数量需为 0～20")
        if n>r.available then fail(r.id.." 剩余容量不足，最多可新增 "..r.available.." 个") end
        if n>0 then
            if tostring(u:get("wireless",r.id,"disabled") or "0")=="1" then fail(r.id.." 已关闭，请先启用该频段") end
            selected[#selected+1]={radio=r.id,count=n}
        end
        total=total+n
    end
    for id,v in pairs(counts) do
        if not u:get("wireless",id) and tonumber(v)~=0 then fail("不存在的无线设备") end
    end
    if total<1 or total>20 then fail("单次新增总数量需为 1～20") end
    if start+total-1>9999 then fail("无线编号超出 9999") end
    local node=tostring(req.node or "")
    if node~="" then
        local s=u:get_all("passwall2",node)
        if not s or s[".type"]~="nodes" or tostring(s.protocol or ""):sub(1,1)=="_" then fail("请选择有效代理节点") end
        if u:get("juliang_fastacl","main","runtime_mode")=="normal_proxy" then fail("普通代理模式下请先创建直连无线，再在代理插件中配置") end
    end
    local ssids, ranges = {}, {}
    u:foreach("wireless","wifi-iface",function(s) ssids[s.ssid or ""]=true end)
    u:foreach("network","interface",function(s)
        for _,ip in ipairs(words(s.ipaddr)) do local r=range(ip,s.netmask); if r then ranges[#ranges+1]=r end end
    end)
    for _,r in ipairs(env.routes()) do ranges[#ranges+1]=r end
    local rows={}; local nextid=1; local subnet=1
    for _,choice in ipairs(selected) do
        for _=1,choice.count do
            local ssid=prefix..string.format("%02d",start+#rows)
            if #ssid>32 then fail("无线名称超过 32 字节："..ssid) end
            if ssids[ssid] then fail("无线名称已存在："..ssid) end; ssids[ssid]=true
            while nextid<=9999 and (u:get("network","jfaw"..nextid) or u:get("wireless","jfaw"..nextid) or u:get("dhcp","jfaw"..nextid) or u:get("network","jfaw"..nextid.."_dev") or u:get("firewall","jfaw"..nextid)) do nextid=nextid+1 end
            if nextid>9999 then fail("无法分配无线配置名称") end
            local cidr,ip
            while subnet<=762 do
                local block=math.floor((subnet-1)/254); local oct=(subnet-1)%254+1
                local base=({"10.231.","172.29.","192.168."})[block+1]
                ip=base..oct..".1"; cidr=base..oct..".0/24"
                local r=range(cidr,24); local clash=false
                for _,existing in ipairs(ranges) do if r[1]<=existing[2] and existing[1]<=r[2] then clash=true;break end end
                subnet=subnet+1
                if not clash then ranges[#ranges+1]=r; break end
                ip=nil
            end
            if not ip then fail("没有可用的独立网段") end
            rows[#rows+1]={section="jfaw"..nextid,network="jfaw"..nextid,device=choice.radio,ssid=ssid,ip=ip,subnet=cidr,node=node,hidden=req.hidden=="1" and "1" or "0"}
            nextid=nextid+1
        end
    end
    return {action=action,rows=rows,revision=env.revision()}
end
function M.mutate(u,plan,req)
    if plan.action=="clear" then
        local nets={}; for _,row in ipairs(plan.rows) do nets[row.network]=true end
        -- Tagged objects and FastACL-generated forwards belonging to these zones only.
        for _,cfg in ipairs({"wireless","network","dhcp","firewall","juliang_fastacl"}) do
            local remove={}
            u:foreach(cfg,nil,function(s)
                local generated=cfg=="firewall" and s[".type"]=="forwarding" and (s[".name"]:match("^jfa_direct_ap%d+$") or s[".name"]:match("^jfa_runtime_ap%d+$")) and nets[s.src]
                local ap=cfg=="juliang_fastacl" and s[".type"]=="ap" and nets[s.network]
                if (section_owned(s) and nets[s.jfa_network]) or generated or ap then remove[#remove+1]=s[".name"] end
            end)
            for _,name in ipairs(remove) do assert(u:delete(cfg,name),"删除配置失败") end
        end
        return
    end
    local function add(cfg,kind,name,values,net)
        values.jfa_owner=OWNER; values.jfa_network=net
        if u:get(cfg,name) then fail("配置名称冲突："..name) end
        assert(u:section(cfg,kind,name,values),"建立配置失败")
    end
    for _,row in ipairs(plan.rows) do
        local net=row.network
        add("network","device",net.."_dev",{name="br-"..net,type="bridge",bridge_empty="1",ipv6="0"},net)
        add("network","interface",net,{device="br-"..net,proto="static",ipaddr=row.ip,netmask="255.255.255.0",delegate="0"},net)
        add("dhcp","dhcp",net,{interface=net,start="100",limit="100",leasetime="12h",ra="disabled",dhcpv6="disabled",ndp="disabled",dhcp_option={"6,"..row.ip}},net)
        add("wireless","wifi-iface",row.section,{device=row.device,network=net,mode="ap",ssid=row.ssid,encryption="psk2+ccmp",key=req.key,isolate="1",disabled="0",hidden=row.hidden},net)
        add("firewall","zone",net,{name=net,network={net},input="REJECT",output="ACCEPT",forward="REJECT"},net)
        for _,rule in ipairs({{"dhcp","udp","67"},{"dns","tcp udp","53"}}) do
            add("firewall","rule",net.."_"..rule[1],{name="FastACL "..net.." "..rule[1],src=net,proto=rule[2],dest_port=rule[3],family="ipv4",target="ACCEPT"},net)
        end
    end
end
function M.bind(u,plan)
    local bynet={}; for _,row in ipairs(plan.rows) do bynet[row.network]=row end
    if plan.action~="create" then return end
    local count=0
    u:foreach("juliang_fastacl","ap",function(s)
        local row=bynet[s.network]
        if row then
            u:set("juliang_fastacl",s[".name"],"jfa_owner",OWNER)
            u:set("juliang_fastacl",s[".name"],"jfa_network",row.network)
            u:set("juliang_fastacl",s[".name"],"mode",row.node=="" and "direct_cn" or "proxy")
            if row.node~="" then u:set("juliang_fastacl",s[".name"],"node",row.node) else u:delete("juliang_fastacl",s[".name"],"node") end
            count=count+1
        end
    end)
    if count~=#plan.rows then fail("FastACL 未完整识别新增无线") end
end
M.range=range
M.configs=CONFIGS
return M

module("luci.controller.juliang", package.seeall)

local http = require "luci.http"
local json = require "luci.jsonc"
local sys = require "luci.sys"
local uci = require "luci.model.uci".cursor()

function index()
    entry({"admin", "juliang"}, firstchild(), _("JuLiang"), 1).dependent = false
    entry({"admin", "juliang", "dashboard"}, template("juliang/dashboard"), _("控制中心"), 1)
    entry({"admin", "juliang", "wireless"}, template("juliang/wireless"), _("无线与终端"), 2)
    entry({"admin", "juliang", "api", "egress"}, call("api_egress"), nil).leaf = true
    entry({"admin", "juliang", "api", "status"}, call("api_status"), nil).leaf = true
    entry({"admin", "juliang", "api", "wireless"}, call("api_wireless"), nil).leaf = true
    entry({"admin", "juliang", "api", "wireless_set"}, call("api_wireless_set"), nil).leaf = true
end

local function reply(data)
    http.prepare_content("application/json")
    http.write(json.stringify(data))
end

local function readfile(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local s = f:read("*a"); f:close(); return s
end

local function firstline(cmd)
    local p = io.popen(cmd .. " 2>/dev/null")
    if not p then return "" end
    local s = p:read("*l") or ""; p:close(); return s
end

local function profile_value(path, key)
    local s = readfile(path) or ""
    return s:match("[\r\n]" .. key .. "=([^\r\n]*)") or s:match("^" .. key .. "=([^\r\n]*)") or ""
end

local function profiles(band)
    local suffix = band == "2g" and "b0.dat" or "b1.dat"
    local out, p = {}, io.popen("find /etc/wireless/mediatek -type f -name '*" .. suffix .. "' 2>/dev/null")
    if p then for line in p:lines() do out[#out + 1] = line end p:close() end
    return out
end

local function update_profile(path, values)
    local s = readfile(path)
    if not s then return false end
    for k, v in pairs(values) do
        local n
        s, n = s:gsub("([\r\n])" .. k .. "=[^\r\n]*", "%1" .. k .. "=" .. v, 1)
        if n == 0 then s = s .. "\n" .. k .. "=" .. v .. "\n" end
    end
    local f = io.open(path, "w")
    if not f then return false end
    f:write(s); f:close(); return true
end

local function wireless_ifaces()
    local out, seen, p = {}, {}, io.popen("iwinfo 2>/dev/null | awk '/ESSID/ {print $1}'")
    if p then
        for dev in p:lines() do
            if dev ~= "" and not seen[dev] then out[#out + 1] = dev; seen[dev] = true end
        end
        p:close()
    end
    return out
end

local function stations()
    local out = {}
    for _, dev in ipairs(wireless_ifaces()) do
        local p = io.popen("iwinfo " .. dev .. " assoclist 2>/dev/null")
        if p then
            local current
            for line in p:lines() do
                local mac, signal = line:match("^([%x:]+)%s+([%-0-9]+)%s+dBm")
                if mac then
                    current = { mac = mac:upper(), signal = tonumber(signal) or 0, radio = dev, rx_rate = "--", tx_rate = "--" }
                    out[#out + 1] = current
                elseif current then
                    local rx = line:match("^%s*RX:%s*(.-)%s*$")
                    local tx = line:match("^%s*TX:%s*(.-)%s*$")
                    if rx then current.rx_rate = rx end
                    if tx then current.tx_rate = tx end
                end
            end
            p:close()
        end
    end
    local leases = readfile("/tmp/dhcp.leases") or ""
    for _, c in ipairs(out) do
        for line in leases:gmatch("[^\r\n]+") do
            local _, mac, ip, host = line:match("^(%S+)%s+(%S+)%s+(%S+)%s+(%S+)")
            if mac and mac:upper() == c.mac then c.ip = ip; c.hostname = host ~= "*" and host or "未知设备"; break end
        end
    end
    return out
end

local function uci_enabled(keys)
    for _, key in ipairs(keys) do
        local v = firstline("uci -q get " .. key)
        if v == "1" or v == "true" then return true end
    end
    return false
end

local function service_state(name)
    if name == "nps" then
        return sys.call("[ -x /etc/init.d/nps ] && /etc/init.d/nps status >/dev/null 2>&1") == 0
            or sys.call("pgrep -f '/usr/bin/npc' >/dev/null 2>&1") == 0
    end
    if name == "passwall" then return uci_enabled({"passwall.@global[0].enabled"}) and sys.call("pgrep -f '/tmp/etc/passwall/' >/dev/null 2>&1") == 0 end
    if name == "passwall2" then return uci_enabled({"passwall2.@global[0].enabled"}) and sys.call("pgrep -f '/tmp/etc/passwall2/' >/dev/null 2>&1") == 0 end
    if name == "homeproxy" then
        return sys.call("[ -x /etc/init.d/homeproxy ] && /etc/init.d/homeproxy status >/dev/null 2>&1") == 0
            or sys.call("pgrep -f '/usr/bin/sing-box run.*homeproxy' >/dev/null 2>&1") == 0
    end
    if name == "openclash" then return uci_enabled({"openclash.config.enable"}) and sys.call("pgrep -f 'mihomo|clash' >/dev/null 2>&1") == 0 end
    return false
end

function api_status()
    local wan = json.parse(sys.exec("ubus call network.interface.wan status 2>/dev/null")) or {}
    local dev = wan.l3_device or wan.device or firstline("ip -4 route show default | awk 'NR==1 {print $5}'")
    local rx = tonumber(readfile("/sys/class/net/" .. dev .. "/statistics/rx_bytes") or 0) or 0
    local tx = tonumber(readfile("/sys/class/net/" .. dev .. "/statistics/tx_bytes") or 0) or 0
    local ip = ""
    if wan["ipv4-address"] and wan["ipv4-address"][1] then ip = wan["ipv4-address"][1].address or "" end
    local uptime = tonumber(firstline("cut -d. -f1 /proc/uptime")) or 0
    local ifaces, p = {}, io.popen("for d in /sys/class/net/*; do n=${d##*/}; [ \"$n\" = lo ] && continue; s=$(cat $d/operstate 2>/dev/null); c=$(cat $d/carrier 2>/dev/null); printf '%s|%s|%s\\n' \"$n\" \"$s\" \"$c\"; done")
    if p then for line in p:lines() do local n,s,c=line:match("([^|]+)|([^|]*)|([^|]*)"); if n and n ~= "bonding_masters" and not n:match("^dummy") and not n:match("^apcli") then ifaces[#ifaces+1]={name=n,state=s,carrier=c} end end p:close() end
    local sta = stations()
    local running = {
        passwall=service_state("passwall"), passwall2=service_state("passwall2"),
        homeproxy=service_state("homeproxy"), openclash=service_state("openclash"), nps=service_state("nps")
    }
    local enabled = {
        passwall=uci_enabled({"passwall.@global[0].enabled"}),
        passwall2=uci_enabled({"passwall2.@global[0].enabled"}),
        homeproxy=running.homeproxy or firstline("uci -q get homeproxy.config.main_node") ~= "",
        openclash=uci_enabled({"openclash.config.enable"})
    }
    local active = {}
    for _, name in ipairs({"passwall","passwall2","homeproxy","openclash"}) do
        if enabled[name] and running[name] then active[#active + 1] = name end
    end
    reply({ok=true, version="JuLiang", wan={device=dev, ip=ip, up=wan.up == true, proto=wan.proto or "", rx=rx, tx=tx}, uptime=uptime,
        stations=sta, station_count=#sta, interfaces=ifaces,
        services=running, service_enabled=enabled, active_proxy=active})
end

local function wireless_rows()
    local u = require("luci.model.uci").cursor()
    local runtime = json.parse(sys.exec("ubus call network.wireless status 2>/dev/null")) or {}
    local by_section = {}
    for _, radio in pairs(runtime) do
        for _, it in ipairs(radio.interfaces or {}) do
            if it.section then by_section[it.section] = it.ifname end
        end
    end
    local clients, rows = stations(), {}
    u:foreach("wireless", "wifi-iface", function(f)
        if (f.mode or "ap") ~= "ap" then return end
        local radio = u:get_all("wireless", f.device) or {}
        local ifname = by_section[f[".name"]]
        local associated = {}
        for _, client in ipairs(clients) do
            if ifname and client.radio == ifname then associated[#associated+1] = client end
        end
        rows[#rows+1] = {section=f[".name"], band=radio.band or (radio.hwmode=="11a" and "5g" or "2g"),
            ssid=f.ssid or f[".name"], channel=radio.channel or "auto", hidden=f.hidden=="1",
            available=ifname~=nil and f.disabled~="1", ifname=ifname or "", network=f.network,
            clients=associated, count=#associated}
    end)
    return rows
end

function api_wireless()
    reply({ok=true, radios=wireless_rows()})
end

function api_wireless_set()
    local u = require("luci.model.uci").cursor()
    local action = http.formvalue("action") or "save"
    local section = http.formvalue("section") or ""
    local all = http.formvalue("band") == "all"
    local f = u:get_all("wireless", section)
    if not all and (not f or f[".type"]~="wifi-iface" or (f.mode or "ap")~="ap") then return reply({ok=false,error="无线接口不存在，请刷新"}) end
    if all and action~="hide" and action~="show" then return reply({ok=false,error="invalid action"}) end
    if action=="save" then
        local ssid,key,channel = http.formvalue("ssid") or "",http.formvalue("key") or "",http.formvalue("channel") or ""
        if #ssid<1 or #ssid>32 or ssid:find("[\r\n]") then return reply({ok=false,error="SSID 格式错误"}) end
        if key~="" and (#key<8 or #key>63 or key:find("[\r\n]")) then return reply({ok=false,error="密码必须为 8-63 个字符"}) end
        if channel~="auto" and not channel:match("^%d+$") then return reply({ok=false,error="信道格式错误"}) end
        u:set("wireless",section,"ssid",ssid)
        if key~="" then u:set("wireless",section,"key",key);u:set("wireless",section,"encryption","psk2+ccmp") end
        u:set("wireless",f.device,"channel",channel)
    elseif action=="hide" or action=="show" then
        if all then
            u:foreach("wireless","wifi-iface",function(x) if (x.mode or "ap")=="ap" then u:set("wireless",x[".name"],"hidden",action=="hide" and "1" or "0") end end)
        else u:set("wireless",section,"hidden",action=="hide" and "1" or "0") end
    else return reply({ok=false,error="invalid action"}) end
    u:commit("wireless")
    sys.call("(sleep 1; wifi reload >/tmp/juliang-wireless-reload.log 2>&1) >/dev/null 2>&1 &")
    reply({ok=true})
end


-- Deliberately separate from the two-second status polling.
function api_egress()
    local fs = require "nixio.fs"
    local cache = "/tmp/juliang-egress.json"
    local cached = json.parse(fs.readfile(cache) or "")
    if cached and cached.checked_at and os.time() - cached.checked_at >= 0 and os.time() - cached.checked_at < 60 then
        reply(cached); return
    end
    local raw = sys.exec("curl -4 -fsS --connect-timeout 4 --max-time 10 https://ipwho.is/ 2>/dev/null | head -c 16384")
    local data = json.parse(raw or "")
    if not data or data.success ~= true or type(data.ip) ~= "string" or not data.ip:match("^%d+%.%d+%.%d+%.%d+$") then
        reply({ok=false,error="出口检测失败，请稍后重试"}); return
    end
    local result = {ok=true,ip=data.ip,country=data.country or "",country_code=data.country_code or "",region=data.region or "",city=data.city or "",isp=(data.connection or {}).isp or "",source="ipwho.is",scope="router",checked_at=os.time()}
    fs.writefile(cache,json.stringify(result))
    reply(result)
end

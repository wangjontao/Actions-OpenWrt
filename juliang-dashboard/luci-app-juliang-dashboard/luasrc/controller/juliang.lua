module("luci.controller.juliang", package.seeall)

local http = require "luci.http"
local json = require "luci.jsonc"
local sys = require "luci.sys"

function index()
    entry({"admin", "juliang"}, firstchild(), _("JuLiangTK"), 1).dependent = false
    entry({"admin", "juliang", "dashboard"}, template("juliang/dashboard"), _("控制中心"), 1)
    entry({"admin", "juliang", "wireless"}, template("juliang/wireless"), _("无线与终端"), 2)
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

local function service_state(name)
    return sys.call("/etc/init.d/" .. name .. " enabled >/dev/null 2>&1") == 0 and
        sys.call("/etc/init.d/" .. name .. " running >/dev/null 2>&1") == 0
end

local function uci_enabled(keys)
    for _, key in ipairs(keys) do
        local v = firstline("uci -q get " .. key)
        if v == "1" or v == "true" then return true end
    end
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
    if p then for line in p:lines() do local n,s,c=line:match("([^|]+)|([^|]*)|([^|]*)"); if n then ifaces[#ifaces+1]={name=n,state=s,carrier=c} end end p:close() end
    local sta = stations()
    local running = {
        passwall=service_state("passwall"), passwall2=service_state("passwall2"),
        homeproxy=service_state("homeproxy"), openclash=service_state("openclash"), nps=service_state("nps")
    }
    local enabled = {
        passwall=uci_enabled({"passwall.@global[0].enabled"}),
        passwall2=uci_enabled({"passwall2.@global[0].enabled"}),
        homeproxy=uci_enabled({"homeproxy.config.main.enabled", "homeproxy.@homeproxy[0].enabled"}),
        openclash=uci_enabled({"openclash.config.enable"})
    }
    local active = {}
    for _, name in ipairs({"passwall","passwall2","homeproxy","openclash"}) do
        if enabled[name] and running[name] then active[#active + 1] = name end
    end
    reply({ok=true, version="JuLiangV1", wan={device=dev, ip=ip, up=wan.up == true, proto=wan.proto or "", rx=rx, tx=tx}, uptime=uptime,
        stations=sta, station_count=#sta, interfaces=ifaces,
        services=running, service_enabled=enabled, active_proxy=active})
end

local function radio_info(band)
    local ps = profiles(band); local path = ps[1]
    if not path then return {band=band, available=false, clients={}} end
    local clients = stations(); local filtered = {}
    local want = band == "2g" and "ra" or "rax"
    for _, c in ipairs(clients) do if c.radio:match("^" .. want) then filtered[#filtered+1]=c end end
    return {band=band,available=true,ssid=profile_value(path,"SSID1"),channel=profile_value(path,"Channel"),hidden=profile_value(path,"HideSSID") == "1",clients=filtered,count=#filtered}
end

function api_wireless()
    reply({ok=true, radios={radio_info("2g"),radio_info("5g")}})
end

function api_wireless_set()
    local band = http.formvalue("band") or ""
    local action = http.formvalue("action") or "save"
    if band ~= "2g" and band ~= "5g" and band ~= "all" then return reply({ok=false,error="invalid band"}) end
    local targets = band == "all" and {"2g","5g"} or {band}
    local values = {}
    if action == "hide" then values.HideSSID = "1"
    elseif action == "show" then values.HideSSID = "0"
    elseif action == "save" then
        local ssid = http.formvalue("ssid") or ""
        local key = http.formvalue("key") or ""
        local channel = http.formvalue("channel") or ""
        if #ssid < 1 or #ssid > 32 or ssid:find("[\r\n]") then return reply({ok=false,error="SSID 格式错误"}) end
        if key ~= "" and (#key < 8 or #key > 63 or key:find("[\r\n]")) then return reply({ok=false,error="密码必须为 8-63 个字符"}) end
        if not channel:match("^%d+$") then return reply({ok=false,error="信道格式错误"}) end
        values.SSID1=ssid; values.Channel=channel; values.AuthMode="WPA2PSK"; values.EncrypType="AES"
        if key ~= "" then values.WPAPSK1=key end
    else return reply({ok=false,error="invalid action"}) end
    local changed = 0
    for _, b in ipairs(targets) do for _, path in ipairs(profiles(b)) do if update_profile(path, values) then changed=changed+1 end end end
    if changed == 0 then return reply({ok=false,error="未找到无线配置"}) end
    sys.call("(sleep 1; wifi reload >/dev/null 2>&1 || /etc/init.d/mtwifi restart >/dev/null 2>&1) &")
    reply({ok=true,changed=changed})
end


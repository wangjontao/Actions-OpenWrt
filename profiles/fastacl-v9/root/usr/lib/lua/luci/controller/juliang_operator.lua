module("luci.controller.juliang_operator", package.seeall)

function index()
    local page = entry({"admin", "network", "wireless_operator"}, template("juliang_operator/wireless"), _("无线"), 15)
    page.leaf = true
    page.dependent = false
    page.acl_depends = { "juliang-wireless-operator" }

    local api = entry({"admin", "network", "wireless_operator_api"}, call("handle_wireless"), nil)
    api.leaf = true
    api.dependent = false
    api.acl_depends = { "juliang-wireless-operator" }

    local dash = entry({"admin", "juliang_operator_api"}, call("handle_dashboard"), nil)
    dash.leaf = true
    dash.dependent = false
    dash.acl_depends = { "juliang-operator-home" }
end

local function write_json(t)
    local http = require "luci.http"
    local jsonc = require "luci.jsonc"
    http.prepare_content("application/json")
    http.write(jsonc.stringify(t))
end


local function readfile(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    if not s then return nil end
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    return s
end

local function exec_json(cmd)
    local sys = require "luci.sys"
    local jsonc = require "luci.jsonc"
    local out = sys.exec(cmd .. " 2>/dev/null") or ""
    if out == "" then return {} end
    local ok, obj = pcall(jsonc.parse, out)
    if ok and type(obj) == "table" then return obj end
    return {}
end

local function runtime_wireless_map()
    local st = exec_json("ubus call network.wireless status")
    local by_section, by_ssid = {}, {}

    for _, radio in pairs(st) do
        if type(radio) == "table" and type(radio.interfaces) == "table" then
            for _, it in ipairs(radio.interfaces) do
                if type(it) == "table" then
                    local cfg = type(it.config) == "table" and it.config or {}
                    local section = it.section or cfg.section
                    local ifname = it.ifname or cfg.ifname
                    local ssid = cfg.ssid
                    if section and ifname then by_section[section] = ifname end
                    if ssid and ifname and not by_ssid[ssid] then by_ssid[ssid] = ifname end
                end
            end
        end
    end

    return by_section, by_ssid
end

local function host_map()
    local map = {}

    local f = io.open("/tmp/dhcp.leases", "r")
    if f then
        for line in f:lines() do
            local _, mac, ip, name = line:match("^(%S+)%s+(%S+)%s+(%S+)%s+(%S+)")
            if mac and ip then
                map[mac:lower()] = { ip = ip, name = (name ~= "*" and name or "") }
            end
        end
        f:close()
    end

    local arp = io.open("/proc/net/arp", "r")
    if arp then
        for line in arp:lines() do
            local ip, _, _, mac = line:match("^(%S+)%s+(%S+)%s+(%S+)%s+(%S+)")
            if ip and mac and mac:match("^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$") then
                local k = mac:lower()
                map[k] = map[k] or { ip = ip, name = "" }
                if not map[k].ip or map[k].ip == "" then map[k].ip = ip end
            end
        end
        arp:close()
    end

    local sys = require "luci.sys"
    local neigh = sys.exec("ip neigh show 2>/dev/null") or ""
    for line in neigh:gmatch("[^\r\n]+") do
        local ip, mac = line:match("^(%S+).-[Ll][Ll][Aa][Dd][Dd][Rr]%s+(%S+)")
        if ip and mac and mac:match("^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$") then
            local k = mac:lower()
            map[k] = map[k] or { ip = ip, name = "" }
            if not map[k].ip or map[k].ip == "" then map[k].ip = ip end
        end
    end

    return map
end

local function station_list(ifname, hosts)
    if not ifname or not ifname:match("^[%w%._%-]+$") then return {} end

    local util = require "luci.util"
    local jsonc = require "luci.jsonc"
    local arg = jsonc.stringify({ device = ifname })
    local obj = exec_json("ubus call iwinfo assoclist " .. util.shellquote(arg))
    local rows = obj.results or obj
    local out = {}

    if type(rows) ~= "table" then return out end

    for _, s in ipairs(rows) do
        if type(s) == "table" then
            local mac = tostring(s.mac or s.addr or ""):lower()
            if mac ~= "" then
                local h = hosts[mac] or {}
                local rx = type(s.rx) == "table" and s.rx or {}
                local tx = type(s.tx) == "table" and s.tx or {}
                out[#out + 1] = {
                    mac = mac:upper(),
                    ip = h.ip or "",
                    name = h.name or "",
                    signal = tonumber(s.signal or 0) or 0,
                    noise = tonumber(s.noise or 0) or 0,
                    inactive = tonumber(s.inactive or 0) or 0,
                    rx_bytes = tonumber(rx.bytes or s.rx_bytes or 0) or 0,
                    tx_bytes = tonumber(tx.bytes or s.tx_bytes or 0) or 0,
                    rx_rate = tonumber(rx.rate or s.rx_rate or 0) or 0,
                    tx_rate = tonumber(tx.rate or s.tx_rate or 0) or 0
                }
            end
        end
    end

    table.sort(out, function(a,b) return a.mac < b.mac end)
    return out
end

local function wireless_clients(uci)
    local by_section, by_ssid = runtime_wireless_map()
    local hosts = host_map()
    local groups = {}

    uci:foreach("wireless", "wifi-iface", function(s)
        if tostring(s.disabled or "0") ~= "1" and tostring(s.mode or "ap") == "ap" then
            local section = s[".name"] or ""
            local ifname = by_section[section] or s.ifname or by_ssid[s.ssid or ""]
            local clients = station_list(ifname, hosts)
            groups[#groups + 1] = {
                section = section,
                ssid = s.ssid or section,
                device = s.device or "",
                network = s.network or "",
                ifname = ifname or "",
                count = #clients,
                clients = clients
            }
        end
    end)

    table.sort(groups, function(a,b)
        if a.device == b.device then return a.section < b.section end
        return a.device < b.device
    end)
    return groups
end

local function wan_status(uci)
    local st = exec_json("ubus call network.interface.wan status")
    local dev = st.l3_device or st.device or uci:get("network", "wan", "device") or ""
    local ip = ""
    local gw = ""

    local addrs = st["ipv4-address"]
    if type(addrs) == "table" and type(addrs[1]) == "table" then
        ip = addrs[1].address or ""
    end

    local routes = st.route
    if type(routes) == "table" then
        for _, r in ipairs(routes) do
            if type(r) == "table" and (r.target == "0.0.0.0" or tonumber(r.mask or -1) == 0) then
                gw = r.nexthop or ""
                break
            end
        end
    end

    if ip == "" and dev:match("^[%w%._%-]+$") then
        local sys = require "luci.sys"
        ip = (sys.exec("ip -4 -o addr show dev " .. dev .. " 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1") or ""):gsub("%s+$","")
    end

    local rx = tonumber(readfile("/sys/class/net/" .. dev .. "/statistics/rx_bytes") or "0") or 0
    local tx = tonumber(readfile("/sys/class/net/" .. dev .. "/statistics/tx_bytes") or "0") or 0

    return {
        up = st.up == true,
        ip = ip,
        device = dev,
        proto = st.proto or uci:get("network", "wan", "proto") or "",
        gateway = gw,
        uptime = tonumber(st.uptime or 0) or 0,
        rx_bytes = rx,
        tx_bytes = tx
    }
end

local function port_status(uci, wan_dev)
    local sys = require "luci.sys"
    local names = {}
    local raw = sys.exec("ls -1 /sys/class/net 2>/dev/null") or ""
    local lan_dev = uci:get("network", "lan", "device") or ""

    for name in raw:gmatch("[^\r\n]+") do
        if name:match("^eth%d") or name:match("^lan%d") or name:match("^wan%d*$") then
            names[#names + 1] = name
        end
    end
    table.sort(names)

    local out = {}
    for _, name in ipairs(names) do
        local carrier = readfile("/sys/class/net/" .. name .. "/carrier")
        local oper = readfile("/sys/class/net/" .. name .. "/operstate") or "unknown"
        local speed = tonumber(readfile("/sys/class/net/" .. name .. "/speed") or "0") or 0
        if speed < 0 then speed = 0 end
        local role = ""
        if name == wan_dev then role = "WAN"
        elseif name == lan_dev or name:match("^lan%d") then role = "LAN" end

        out[#out + 1] = {
            name = name,
            role = role,
            connected = (carrier == "1" or oper == "up"),
            operstate = oper,
            speed = speed
        }
    end
    return out
end

local function valid_channel(v)
    if v == "auto" then return true end
    local n = tonumber(v or "")
    return n and n >= 1 and n <= 196
end

local function wifi_status(uci)
    local devices, ifaces = {}, {}

    uci:foreach("wireless", "wifi-device", function(s)
        devices[#devices + 1] = {
            section = s[".name"] or "",
            type = s.type or "",
            band = s.band or "",
            hwmode = s.hwmode or "",
            channel = s.channel or "auto",
            txpower = s.txpower or ""
        }
    end)

    uci:foreach("wireless", "wifi-iface", function(s)
        if tostring(s.disabled or "0") ~= "1" then
            ifaces[#ifaces + 1] = {
                section = s[".name"] or "",
                device = s.device or "",
                ssid = s.ssid or "",
                encryption = s.encryption or "none",
                network = s.network or "",
                mode = s.mode or "ap"
            }
        end
    end)

    table.sort(devices, function(a,b) return a.section < b.section end)
    table.sort(ifaces, function(a,b)
        if a.device == b.device then return a.section < b.section end
        return a.device < b.device
    end)

    return devices, ifaces
end

function handle_wireless()
    local http = require "luci.http"
    local uci = require("uci").cursor()
    local action = http.formvalue("action") or "status"

    if action == "status" then
        local devices, ifaces = wifi_status(uci)
        write_json({ok=true, devices=devices, ifaces=ifaces})
        return
    end

    if action == "clients" then
        write_json({ok=true, groups=wireless_clients(uci), timestamp=os.time()})
        return
    end

    if action ~= "save" then
        write_json({ok=false,error="BAD_ACTION"})
        return
    end

    local section = http.formvalue("section") or ""
    local device = http.formvalue("device") or ""
    local ssid = http.formvalue("ssid") or ""
    local key = http.formvalue("key") or ""
    local channel = http.formvalue("channel") or ""

    local iface = uci:get_all("wireless", section)
    local radio = uci:get_all("wireless", device)

    if not iface or iface[".type"] ~= "wifi-iface" then
        write_json({ok=false,error="BAD_IFACE"})
        return
    end
    if not radio or radio[".type"] ~= "wifi-device" then
        write_json({ok=false,error="BAD_DEVICE"})
        return
    end
    if (iface.device or "") ~= device then
        write_json({ok=false,error="DEVICE_MISMATCH"})
        return
    end
    if ssid == "" or #ssid > 32 then
        write_json({ok=false,error="BAD_SSID"})
        return
    end
    if channel ~= "" and not valid_channel(channel) then
        write_json({ok=false,error="BAD_CHANNEL"})
        return
    end
    if key ~= "" and (#key < 8 or #key > 63) then
        write_json({ok=false,error="BAD_KEY"})
        return
    end

    uci:set("wireless", section, "ssid", ssid)
    if key ~= "" then
        uci:set("wireless", section, "key", key)
    end
    if channel ~= "" then
        uci:set("wireless", device, "channel", channel)
    end
    uci:commit("wireless")

    require("luci.sys").call("(sleep 1; wifi reload >/tmp/juliang-operator-wireless.log 2>&1) >/dev/null 2>&1 &")

    write_json({ok=true, section=section, device=device, ssid=ssid, channel=(channel ~= "" and channel or (radio.channel or "auto"))})
end


function handle_dashboard()
    local uci = require("uci").cursor()
    local wan = wan_status(uci)
    write_json({
        ok = true,
        timestamp = os.time(),
        wan = wan,
        ports = port_status(uci, wan.device)
    })
end

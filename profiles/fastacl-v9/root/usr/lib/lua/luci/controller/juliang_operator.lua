module("luci.controller.juliang_operator", package.seeall)

function index()
    local page = entry({"admin", "network", "wireless_operator"}, template("juliang_operator/wireless"), _("无线"), 15)
    page.leaf = true
    page.dependent = false
    page.acl_depends = { "juliang-wireless-operator-edit" }

    local api = entry({"admin", "network", "wireless_operator_api"}, call("handle_wireless"), nil)
    api.leaf = true
    api.dependent = false
    api.acl_depends = { "juliang-wireless-operator-edit" }
end

local function write_json(t)
    local http = require "luci.http"
    local jsonc = require "luci.jsonc"
    http.prepare_content("application/json")
    http.write(jsonc.stringify(t))
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
    local uci = require("luci.model.uci").cursor()
    local action = http.formvalue("action") or "status"

    if action == "status" then
        local devices, ifaces = wifi_status(uci)
        write_json({ok=true, devices=devices, ifaces=ifaces})
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

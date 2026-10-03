#!/usr/bin/lua
local jsonc=require "luci.jsonc"
local API="http://127.0.0.1:9097"
local CONFIG="/etc/fastc/config.yaml"
local function shq(s)return "'"..tostring(s or ""):gsub("'","'\\''").."'" end
local function trim(s)return (tostring(s or ""):gsub("^%s+",""):gsub("%s+$","")) end
local function readf(path)local f=io.open(path,"rb");if not f then return "" end;local s=f:read("*a") or "";f:close();return s end
local function api_ready() return os.execute("curl -fsS --connect-timeout 1 --max-time 1 "..shq(API.."/version").." >/dev/null 2>&1")==0 end
local p=io.popen("lua /usr/libexec/fastc-generate.lua 2>/tmp/fastc-v020-generate.err")
local raw=p and (p:read("*a") or "") or ""; if p then p:close() end
local ok,obj=pcall(jsonc.parse,raw)
if not ok or type(obj)~="table" or obj.ok~=true then io.write(jsonc.stringify({ok=false,error="GENERATE_FAILED",detail=raw},true),"\n");os.exit(1) end
if os.execute("/usr/bin/mihomo -t -d /etc/fastc -f "..shq(CONFIG).." >/tmp/fastc-v020-check.log 2>&1")~=0 then io.write(jsonc.stringify({ok=false,error="CONFIG_INVALID",detail=trim(readf('/tmp/fastc-v020-check.log'))},true),"\n");os.exit(1) end
if not api_ready() then io.write(jsonc.stringify({ok=true,hot=false,offline=true,restarted=false},true),"\n");os.exit(0) end
local payload=jsonc.stringify({path=CONFIG})
local cmd="curl -fsS --connect-timeout 1 --max-time 6 -o /tmp/fastc-v020-reload.body -w '%{http_code}' -X PUT -H 'Content-Type: application/json' --data "..shq(payload).." "..shq(API.."/configs?force=true").." 2>/tmp/fastc-v020-reload.err"
local cp=io.popen(cmd); local code=cp and trim(cp:read("*a") or "") or ""; if cp then cp:close() end
if code~="200" and code~="204" then io.write(jsonc.stringify({ok=false,error="HOT_RELOAD_FAILED",detail="HTTP_"..code..":"..trim(readf('/tmp/fastc-v020-reload.body'))},true),"\n");os.exit(1) end
os.execute("lua /usr/libexec/fastc-sync.lua >/tmp/fastc-v020-sync.json 2>/tmp/fastc-v020-sync.err || true")
io.write(jsonc.stringify({ok=true,hot=true,restarted=false,http=code},true),"\n")

from pathlib import Path
import sys,json
from lupa.lua51 import LuaRuntime
p=Path(__file__).resolve().parents[1]/'root';lua=LuaRuntime(unpack_returned_tuples=True)
for path in [p/'usr/lib/lua/juliang_reboot.lua',p/'usr/lib/lua/luci/controller/juliang_center.lua']:lua.execute('assert(loadstring(...))',path.read_text(encoding='utf-8'))
lua.globals().decode=lambda s:to_lua(json.loads(s)) if s else None
def to_lua(x):
 if isinstance(x,dict):return lua.table_from({k:to_lua(v) for k,v in x.items()})
 return x
def native(x):return {k:native(v) for k,v in x.items()} if hasattr(x,'items') else x
lua.globals().encode=lambda x:json.dumps(native(x))
lua.execute('''
files={};dirs={};clock=10;fired=0;spawned=0;seq=0;spawnok=true
fs={readfile=function(p)return files[p]end,writefile=function(p,s)files[p]=s;return true end,
 mkdir=function(p)if dirs[p]then return false end;dirs[p]=true;return true end,rmdir=function(p)dirs[p]=nil;return true end,
 chmod=function()end,remove=function(p)files[p]=nil;return true end,
 rename=function(a,b)files[b]=files[a];files[a]=nil;return true end}
deps={fs=fs,json={parse=decode,stringify=encode},now=function()return clock end,
 token=function()seq=seq+1;return seq==1 and '11111111-1111-1111-1111-111111111111' or '22222222-2222-2222-2222-222222222222'end,
 spawn=function(delay,id)spawned=spawned+1;return spawnok end,reboot=function()fired=fired+1;return true end}
''')
m=lua.execute((p/'usr/lib/lua/juliang_reboot.lua').read_text(encoding='utf-8'));lua.globals().reboot=m
lua.execute('''
s=reboot.new(deps);assert(not s.status().pending)
assert(s.schedule(60).remaining==60);assert(spawned==1 and fired==0)
assert(not pcall(s.schedule,60));clock=30;assert(s.status().remaining==40)
s.cancel();clock=80;assert(not s.fire('11111111-1111-1111-1111-111111111111'));assert(fired==0)
s.schedule(60);clock=139;assert(not s.fire('22222222-2222-2222-2222-222222222222'))
clock=140;assert(not s.fire('11111111-1111-1111-1111-111111111111'));assert(fired==0)
assert(s.fire('22222222-2222-2222-2222-222222222222'));assert(fired==1)
assert(not s.fire('22222222-2222-2222-2222-222222222222'));assert(fired==1)
assert(not pcall(s.cancel));files['/tmp/juliang-reboot/state.json']=nil
spawnok=false;assert(not pcall(s.schedule,2));assert(not s.status().pending)
assert(not pcall(s.schedule,1));assert(not pcall(s.schedule,'60'))
''')
lua.execute('''
allowed=false;calls=0;httpstatus=200;response=nil;action='now'
package.loaded['luci.dispatcher']={context={authsession='test-session'}}
package.loaded['luci.util']={ubus=function()return {access=allowed}end}
package.loaded['luci.http']={status=function(code)httpstatus=code end,formvalue=function()return action end,prepare_content=function()end,write=function(s)response=s end}
package.loaded['luci.jsonc']={parse=decode,stringify=encode}
package.loaded['juliang_reboot']={service=function()return {schedule=function(delay)calls=calls+1;assert(delay==2 or delay==60);return {pending=true,remaining=delay}end,cancel=function()calls=calls+1;return {pending=false}end}end}
''')
lua.execute((p/'usr/lib/lua/luci/controller/juliang_center.lua').read_text(encoding='utf-8'))
lua.execute('''local c=package.loaded['luci.controller.juliang_center'];c.reboot_action();assert(httpstatus==403 and calls==0)
allowed=true;httpstatus=200;c.reboot_action();assert(calls==1)
action='delay';c.reboot_action();assert(calls==2)
action='cancel';c.reboot_action();assert(calls==3)
action='other';c.reboot_action();assert(calls==3)
''')
print('PASS fake-clock countdown, cancel/replacement races, no early/duplicate reboot, spawn rollback, permission check and action whitelist; no real reboot executed')

acl=json.loads((p/'usr/share/rpcd/acl.d/juliang-fastacl252.json').read_text(encoding='utf-8'))
assert acl['juliang-center']['write']=={'ubus':{'system':['reboot']}}
assert "uci add_list rpcd.juliang_operator.write='juliang-center'" in (p/'etc/uci-defaults/96-juliang-center').read_text(encoding='utf-8')

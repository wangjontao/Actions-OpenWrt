"""Test first-boot menu migration in memory, without a router or service reload."""
from pathlib import Path
import json
from lupa.lua51 import LuaRuntime
ROOT=Path(__file__).resolve().parents[1]
lua=LuaRuntime(unpack_returned_tuples=True)
def table(x):
    if isinstance(x,dict):return lua.table_from({k:table(v) for k,v in x.items()})
    if isinstance(x,list):return lua.table_from([table(v) for v in x])
    return x
def native(x):
    if hasattr(x,'items'):return {k:native(v) for k,v in x.items()}
    return x
files={
 '/usr/share/luci/menu.d/base.json':json.dumps({'admin/services':{'title':'Services','action':{'type':'firstchild'}},'admin/network':{'title':'Network'}}),
 '/usr/share/luci/menu.d/apps.json':json.dumps({'admin/services/upnp':{'title':'UPnP','action':{'type':'view','path':'upnp/upnp'}},'admin/services/ddns':{'title':'DDNS'},'admin/services/wol':{'title':'WOL'},'admin/services/ksmbd':{'title':'Shares'},'admin/statistics':{'title':'Stats'}}),
 '/usr/lib/lua/luci/controller/nps.lua':'old controller',
 '/usr/libexec/juliang-nps-controller.lua':(ROOT/'root/usr/libexec/juliang-nps-controller.lua').read_text(encoding='utf-8'),
 '/usr/share/ucode/luci/template/themes/argon/header.ut':'<head><script id="juliang-menu-revision">old</script></head><a class="brand">JuLtiang 控制中心</a>',
}
lua.globals().read=lambda p:files.get(p)
lua.globals().write=lambda p,s:files.__setitem__(p,s) or True
lua.globals().exists=lambda p:p in files
lua.globals().decode=lambda s:table(json.loads(s))
lua.globals().encode=lambda t:json.dumps(native(t),ensure_ascii=False)
lua.execute("""
package.loaded['nixio.fs']={readfile=read,writefile=write,access=exists,chmod=function()end,remove=function()end,
 dir=function()local i=0;local a={'base.json','apps.json'};return function()i=i+1;return a[i]end end,
 glob=function()return function()return nil end end}
package.loaded['luci.jsonc']={parse=decode,stringify=encode}
""")
script=(ROOT/'root/usr/libexec/juliang-menu-cleanup.lua').read_text(encoding='utf-8')
for _ in range(2):lua.execute(script)
base=json.loads(files['/usr/share/luci/menu.d/base.json']);apps=json.loads(files['/usr/share/luci/menu.d/apps.json'])
assert 'title' not in base['admin/services'] and base['admin/network']['title']=='Network'
assert apps['admin/network/upnp']['action']['path']=='upnp/upnp' and 'admin/services/upnp' not in apps
for key in ['ddns','wol','ksmbd']:assert 'title' not in apps['admin/services/'+key]
assert 'admin/statistics' not in apps
assert files['/usr/lib/lua/luci/controller/nps.lua']==files['/usr/libexec/juliang-nps-controller.lua']
header=files['/usr/share/ucode/luci/template/themes/argon/header.ut']
assert header.count('id="juliang-menu-revision"')==1 and '255-device-subscription-list-1' in header
assert '>JuLiang</span><span' in header and '>控制中心</span></a>' in header
assert header.count('white-space:nowrap')==2
print('PASS idempotent first-boot menu migration, compatibility payload and session menu invalidation')

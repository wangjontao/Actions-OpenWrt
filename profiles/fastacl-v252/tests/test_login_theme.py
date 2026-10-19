from pathlib import Path
from lupa.lua51 import LuaRuntime
ROOT=Path(__file__).resolve().parents[1]
lua=LuaRuntime()
original='<div class="login-page"><a class="brand"><span class="brand-text">{{ hostname }}</span></a><form method="post" action="{{ http.getenv(\"REQUEST_URI\") }}"><input name="luci_username" value="{{ entityencode(duser, true) }}"><input name="luci_password" type="password"></form></div>'
path='/usr/share/ucode/luci/template/themes/argon/sysauth.ut';files={path:original}
lua.globals().read=lambda p:files.get(p)
lua.globals().write=lambda p,s:files.__setitem__(p,s) or True
lua.globals().exists=lambda p:p in files
lua.globals().rename=lambda a,b:files.__setitem__(b,files.pop(a)) or True
lua.execute("package.loaded['nixio.fs']={readfile=read,writefile=write,access=exists,rename=rename,chmod=function()end}")
script=(ROOT/'root/usr/libexec/juliang-login-theme.lua').read_text(encoding='utf-8')
lua.execute(script);after=files.copy();lua.execute(script);assert files==after
changed=files[path]
assert changed.count('id="juliang-login-style"')==1 and 'JuLiang Network Control Center' in changed
expected=original.replace('value="{{ entityencode(duser, true) }}"','value=""')
assert changed[changed.index('<form '):changed.index('</form>')]==expected[expected.index('<form '):expected.index('</form>')]
assert 'name="luci_username" value=""' in changed
assert files[path+'.before-juliang-login']==original
print('PASS login theme idempotence and blank username and unchanged authentication handler')

from pathlib import Path
from lupa.lua51 import LuaRuntime
source=(Path(__file__).resolve().parents[1] / 'root/usr/libexec/fastacl252-control.lua').read_text(encoding='utf-8')
def case(initial, replies, expected, signal=True):
 lua=LuaRuntime(unpack_returned_tuples=True)
 lua.globals().arg=lua.table_from({1:'dae',2:'123'})
 lua.globals().initial=initial
 lua.globals().replies=lua.table_from(replies)
 lua.globals().signal_success=signal
 lua.execute('''
progress=initial;signals=0;polls=0;writes={}
package.loaded['nixio.fs']={
 readfile=function() return progress end,
 writefile=function(path,value) writes[path]=value;progress=value;return true end,
 chmod=function()return true end,
 rename=function()return true end,
 remove=function()progress=nil;return true end
}
package.loaded.nixio={
 kill=function(pid,sig)if sig==10 then signals=signals+1;return signal_success end;return true end,
 nanosleep=function()polls=polls+1;progress=replies[polls] or '1' end
}
os.exit=function(code) error('EXIT:'..code,0) end
io.stderr={write=function()end};print=function()end
''')
 try: lua.execute(source);code=0
 except Exception as e:
  assert 'EXIT:' in str(e),e
  code=int(str(e).split('EXIT:')[1].split()[0])
 assert code==expected,(initial,replies,code,expected)
 return lua
assert case('2\nOK',['1','2\nOK'],0).globals().polls==2
assert case('2\nOK',['3\nInvalid config'],2).globals().signals==1
assert case('1',[],2).globals().signals==0
assert case('2',[],1,False).globals().progress=='2'
# A slow but successful reload must not be killed at the obsolete 8s limit.
assert case('2',['1']*119+['2\nOK'],0).globals().polls==120
# 600 polls at 100ms preserve the explicit 60s safety deadline.
assert case('2',[],124).globals().polls==600
print('PASS: success waits for ack; rejection/busy never report success; signal failure restores status; timeout bounded')

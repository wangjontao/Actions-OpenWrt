from pathlib import Path
import json
from lupa.lua51 import LuaRuntime
lua=LuaRuntime(unpack_returned_tuples=True)
m=lua.execute((Path(__file__).resolve().parents[1]/'root/usr/lib/lua/fastacl252_wireless.lua').read_text(encoding='utf-8'))
def table(v):
 if isinstance(v,dict):return lua.table_from({k:table(x) for k,x in v.items()})
 if isinstance(v,list):return lua.table_from([table(x) for x in v])
 return v
clients='AA:BB:CC:DD:EE:01 -40 dBm / -90 dBm (SNR 50)\n RX: 1200.0 MBit/s\n TX: 600.0 MBit/s\nAA:BB:CC:DD:EE:02 -50 dBm / -90 dBm (SNR 40)\n RX: 144.0 MBit/s\n TX: 72.0 MBit/s\n'
def execute(cmd):
 if cmd.startswith('bridge -j fdb show dev ra0 '):return json.dumps([{'mac':'AA:BB:CC:DD:EE:01','dev':'ra0'}])
 if cmd.startswith('bridge -j fdb show dev rax0 '):return json.dumps([{'mac':'AA:BB:CC:DD:EE:02','dev':'rax0'}])
 if cmd.startswith('iwinfo '):return clients
 if cmd.startswith('/usr/libexec/mtwifi-station-bytes ra0 '):return json.dumps({'ra0/AA:BB:CC:DD:EE:01':{'rx_bytes':123,'tx_bytes':456}})
 if cmd.startswith('/usr/libexec/mtwifi-station-bytes rax0 '):return json.dumps({'rax0/AA:BB:CC:DD:EE:02':{'error':'unsupported'}})
 raise AssertionError(cmd)
sys=lua.table_from({'exec':execute});js=lua.table_from({'parse':lambda s:table(json.loads(s))})
a=m.read_mtwifi('ra0',sys,js);b=m.read_mtwifi('rax0',sys,js)
assert len(a)==len(b)==1 and a[1]['mac']!=b[1]['mac']
assert a[1]['rx_bytes']==123 and a[1]['tx_bytes']==456 and a[1]['rx_link_mbps']==1200
assert b[1]['rx_bytes'] is None and b[1]['tx_bytes'] is None
assert len(m.read_mtwifi('ra0;reboot',sys,js))==0
print('PASS MTWiFi per-BSS identity, link units, vendor counters, unavailable counters and interface validation')

# Scoped FDB JSON uses dev, ifname, or omits the redundant interface name.
for field in ('dev','ifname',None):
 def scoped(cmd):
  if cmd.startswith('bridge -j fdb show dev ra0 '):
   row={'mac':'AA:BB:CC:DD:EE:01'}
   if field: row[field]='ra0'
   return json.dumps([row])
  return execute(cmd)
 result=m.read_mtwifi('ra0',lua.table_from({'exec':scoped}),js)
 assert len(result)==1 and result[1]['mac']=='AA:BB:CC:DD:EE:01',field
# An explicit mismatched owner must still be rejected.
def wrong_owner(cmd):
 if cmd.startswith('bridge -j fdb show dev ra0 '):
  return json.dumps([{'mac':'AA:BB:CC:DD:EE:01','ifname':'rax0'}])
 return execute(cmd)
assert len(m.read_mtwifi('ra0',lua.table_from({'exec':wrong_owner}),js))==0
print('PASS scoped FDB dev/ifname/omitted-owner variants and cross-SSID rejection')

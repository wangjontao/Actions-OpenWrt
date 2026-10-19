from pathlib import Path
import json
from lupa.lua51 import LuaRuntime
ROOT=Path(__file__).resolve().parents[1]
lua=LuaRuntime(unpack_returned_tuples=True)
m=lua.execute((ROOT/'root/usr/lib/lua/fastacl252_wireless.lua').read_text(encoding='utf-8'))
rows=m.parse("""Station 02:00:00:00:00:01 (on phy1-ap0)
        rx bytes: 100000
        tx bytes: 200000
        signal: -51 [-51, -53] dBm
        tx bitrate: 866.7 MBit/s VHT-MCS 9
        rx bitrate: 780.0 MBit/s VHT-MCS 8
        connected time: 312 seconds
Station 02:00:00:00:00:02 (on phy1-ap0)
        signal: -72 dBm
""")
assert len(rows)==2
assert rows[1]['rx_bytes']==100000 and rows[1]['tx_bytes']==200000
assert rows[1]['signal']==-51 and rows[1]['tx_link_mbps']==866.7 and rows[1]['connected_seconds']==312
assert rows[2]['rx_bytes'] is None and rows[2]['signal']==-72
assert len(m.parse(''))==0
account=(ROOT/'root/etc/uci-defaults/96-juliang-center').read_text(encoding='utf-8')
assert "username='admin'" in account and "ADMIN_HASH='$1$" in account
assert "juliang_operator.write='*'" not in account and "juliang_operator.read='*'" not in account
acl=json.loads((ROOT/'root/usr/share/rpcd/acl.d/juliang-fastacl252.json').read_text(encoding='utf-8'))
assert 'system' not in acl['juliang-fastacl252']['write'].get('uci',[])
print('PASS wireless counters, missing fields, signal/link rates and restricted admin invariants')

center=(ROOT/'root/usr/lib/lua/luci/controller/juliang_center.lua').read_text(encoding='utf-8')
assert 'statistics/rx_bytes' in center and 'statistics/tx_bytes' in center
assert 'traffic=counters' in center

from pathlib import Path
import hashlib,ipaddress,json,re
ROOT=Path(__file__).resolve().parents[1]
data=ROOT/'root/usr/share/fastacl252'
meta=json.loads((data/'SPLIT-DATA.json').read_text())
for name,key,minimum in [('cn-ipv4.txt','ipv4',1000),('cn-domains.txt','domains',10000)]:
 b=(data/name).read_bytes();rows=b.decode().splitlines();assert len(rows)==meta[key]['count'] and len(rows)>minimum
 assert hashlib.sha256(b).hexdigest()==meta[key]['sha256'],name
 for row in rows:
  if key=='ipv4':ipaddress.IPv4Network(row,strict=True)
  else:
   assert row==row.lower() and len(row)<=253 and not re.search('[^a-z0-9.-]',row)
   assert all(0<len(part)<=63 and not part.startswith('-') and not part.endswith('-') for part in row.split('.'))
pkg=(ROOT/'package-Makefile').read_text();assert 'test -s $(1)/usr/share/fastacl252/cn-ipv4.txt' in pkg and 'test -s $(1)/usr/share/fastacl252/cn-domains.txt' in pkg
from test_mihomo import lua,config,to_lua,from_lua,policy
lua.execute("local old=io.open;io.open=function(path,mode) if path=='/usr/share/fastacl252/cn-ipv4.txt' then return old("+json.dumps(str(data/'cn-ipv4.txt'))+",mode) end;return old(path,mode) end")
c=config();c['devices'][0].update(split_mode='smart',dns_split='1');core,relay=policy.compile(to_lua(c));fw=from_lua(policy.firewall(to_lua(c),'nft'))['nft'];assert '1.0.1.0/24' in core and 'cn_ipv4' in fw;assert from_lua(relay)['device_policies']['192.168.7.101']['domestic_resolver']
print('PASS packaged split-data hashes, formats and actual smart IPv4 + domestic-DNS policy compilation')

import pathlib, unittest, sys
from lupa.lua51 import LuaRuntime
ROOT=pathlib.Path(__file__).parent
class CompilerTests(unittest.TestCase):
 def setUp(self):
  self.lua=LuaRuntime(unpack_returned_tuples=True)
  self.module=self.lua.execute((ROOT/'compiler.lua').read_text(encoding='utf8'))
 def conf(self):
  return self.lua.eval('''{interface='br-lan',dns_policy='direct',default_mode='direct',
    nodes={us={protocol='socks',dae_uri='socks5://user:pass@203.0.113.2:1080'},
           front={protocol='vless',dae_uri='vless://uuid@203.0.113.3:443'}},
    devices={{mac='02:00:00:00:00:01',ip='192.168.7.101',mode='proxy',node='us'}}}''')
 def test_device_route(self):
  text=self.module.compile(self.conf())
  self.assertIn("mac('02:00:00:00:00:01') && sip(192.168.7.101/32) -> must_exit_us",text)
  self.assertIn('fallback: must_direct',text)
  self.assertIn('dport(53) -> must_direct',text)
  self.assertNotIn('geoip',text)
 def test_chain_order(self):
  c=self.conf(); c.devices[1].preproxy='front'
  self.assertIn('vless://uuid@203.0.113.3:443 -> socks5://user:pass@203.0.113.2:1080',self.module.compile(c))
 def test_identity_guard_before_exit(self):
  text=self.module.compile(self.conf())
  self.assertLess(text.index("!sip(192.168.7.101/32) -> block"),text.index('-> must_exit_us'))
 def test_private_dns_cannot_silently_fall_back(self):
  c=self.conf(); c.dns_policy='private'
  with self.assertRaisesRegex(Exception,'Private DNS adapter'): self.module.compile(c)
 def test_missing_uri_rejected(self):
  c=self.conf(); c.nodes.us.dae_uri=None
  with self.assertRaisesRegex(Exception,'Native dae URI'): self.module.compile(c)
 def test_config_injection_rejected(self):
  c=self.conf(); c.nodes.us.dae_uri='socks5://example:1080\n}\nrouting {'
  with self.assertRaisesRegex(Exception,'Control character'): self.module.compile(c)
 def test_duplicate_exit_shared(self):
  c=self.conf(); d=self.lua.eval("{mac='02:00:00:00:00:02',ip='192.168.7.102',mode='proxy',node='us'}")
  c.devices[2]=d
  self.assertEqual(self.module.compile(c).count('policy: fixed(0)'),1)
if __name__=='__main__':
 if len(sys.argv)>1 and sys.argv[1]=='--fixtures':
  test=CompilerTests(); test.setUp()
  output=pathlib.Path(sys.argv[2]); output.mkdir(parents=True,exist_ok=True)
  for name in ['device','chain','direct']:
   c=test.conf()
   if name=='chain': c.devices[1].preproxy='front'
   if name=='direct': c.devices[1].mode='direct'
   fixture=output/(name+'.dae')
   fixture.write_text(test.module.compile(c),encoding='utf8',newline='\n')
   fixture.chmod(0o600)
 else: unittest.main()

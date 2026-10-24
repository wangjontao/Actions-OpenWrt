"""Regression tests for EEPROM identity, fail-closed setup and legacy DNS compatibility."""
from pathlib import Path
import importlib.util,tempfile,unittest
from lupa.lua51 import LuaRuntime

ROOT=Path(__file__).resolve().parents[1]
class HardwareIdentity(unittest.TestCase):
 def runtime(self,chip=0x7981):
  lua=LuaRuntime(encoding=None,unpack_returned_tuples=True)
  lua.globals().factory=bytes([chip%256,chip//256,0,0,0xb8,0x60,0x61,0x75,0x45,0xc2,0xb8,0x60,0x61,0x75,0x45,0xc3])
  lua.execute(br'''io.open=function(path)
    local value
    if path=='/proc/mtd' then value='mtd7: 00200000 00020000 "Factory"\n'
    elseif path=='/dev/mtd7' then value=factory
    elseif path=='/sbin/mtwifi_cfg' then value='driver' end
    if not value then return nil end
    return {read=function()return value end,close=function()end}
  end''')
  return lua,lua.execute((ROOT/'root/usr/lib/lua/juliang_wifi_hardware.lua').read_bytes())
 def test_both_supported_chips_and_named_partition(self):
  for chip in (0x7981,0x7986):
   lua,module=self.runtime(chip);bases=module.read()
   self.assertEqual(bases[b'2g'],b'b8:60:61:75:45:c2')
   self.assertEqual(bases[b'5g'],b'b8:60:61:75:45:c3')
 def test_reject_reference_and_bad_factory(self):
  for data in (b'\0'*16,b'\x81\x79\0\0'+bytes.fromhex('34ca817deb7b34ca817deb7c'),b'\x81\x79\0\0'+bytes.fromhex('b960617545c2b860617545c3')):
   lua,module=self.runtime();lua.globals().factory=data
   with self.assertRaises(Exception):module.read()
 def test_unknown_layout_refuses_reference_fallback(self):
  lua,module=self.runtime(0x1234)
  with self.assertRaises(Exception):module.read()
 def test_every_setup_replaces_stale_profile_base(self):
  lua,module=self.runtime()
  for band,last in ((b'2g',b'c2'),(b'5g',b'c3')):
   cfg=lua.table_from({b'config':lua.table_from({b'band':band})});dats=lua.table_from({b'MacAddress':b'34:ca:81:7d:eb:7b'})
   module.apply(cfg,dats);self.assertTrue(dats[b'MacAddress'].endswith(last))
 def test_native_driver_does_not_require_factory(self):
  lua,module=self.runtime();lua.execute(b'io.open=function()return nil end')
  self.assertIsNone(module.preflight())
 def test_dns_old_alias_retained_but_not_listed(self):
  lua=LuaRuntime(encoding=None);module=lua.execute((ROOT/'root/usr/lib/lua/fastacl252_dns.lua').read_bytes())
  ids=[row[b'id'] for _,row in module.catalog().items()]
  self.assertNotIn(b'follow_exit',ids);self.assertIn(b'cloudflare',ids)
  self.assertEqual(module.provider(b'follow_exit')[b'ip'],module.provider(b'cloudflare')[b'ip'])

if __name__=='__main__':unittest.main()

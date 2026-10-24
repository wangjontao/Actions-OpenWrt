from pathlib import Path
import os, subprocess, tempfile, unittest
ROOT=Path(__file__).resolve().parents[1]
HELPER=ROOT/'root/usr/libexec/juliang-bbr'
if not HELPER.exists(): HELPER=Path(__file__).parent/'files/root/usr/libexec/juliang-bbr'
class BBRTest(unittest.TestCase):
 def run_case(self,enabled,current='cubic',available='reno cubic bbr',previous=None):
  with tempfile.TemporaryDirectory() as d:
   d=Path(d); prev=d/'previous'; state=d/'current';state.write_text(current)
   if previous is not None:prev.write_text(previous)
   source=HELPER.read_text(encoding='utf-8').replace('/etc/juliang-bbr.previous',prev.as_posix())
   helper=d/'helper';helper.write_text(source,encoding='utf-8')
   script=r'''uci() { printf '%s\n' "$ENABLED"; }
modprobe() { return 0; }
chmod() { return 0; }
sysctl() {
 case "$*" in
 '-n net.ipv4.tcp_congestion_control') cat "$STATE";;
 '-n net.ipv4.tcp_available_congestion_control') printf '%s\n' "$AVAILABLE";;
 '-w net.ipv4.tcp_congestion_control='*) printf '%s' "${2#*=}" > "$STATE";;
 *) echo 'Unexpected sysctl operation' >&2; return 1;;
 esac
}
set -- apply
. "$HELPER"
'''
   shell=os.environ.get('BBR_TEST_SH','sh')
   r=subprocess.run([shell,'-c',script],env={**os.environ,'ENABLED':enabled,'STATE':state.as_posix(),'AVAILABLE':available,'HELPER':helper.as_posix()},capture_output=True,text=True)
   return r.returncode,state.read_text(),prev.read_text().strip() if prev.exists() else None
 def test_enable(self):self.assertEqual(self.run_case('1'),(0,'bbr','cubic'))
 def test_missing_module_keeps_algorithm(self):
  rc,state,old=self.run_case('1',available='reno cubic');self.assertNotEqual(rc,0);self.assertEqual(state,'cubic');self.assertIsNone(old)
 def test_disable_restores_previous(self):self.assertEqual(self.run_case('0',current='bbr',previous='cubic'),(0,'cubic','cubic'))
 def test_invalid_previous_falls_back(self):
  rc,state,_=self.run_case('0',current='bbr',previous='bad;value');self.assertEqual((rc,state),(0,'cubic'))
if __name__=='__main__': unittest.main()

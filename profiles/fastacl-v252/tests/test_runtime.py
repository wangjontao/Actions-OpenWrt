"""Exercise the real runtime against command-boundary stubs, with real child PIDs.

These tests check lifecycle/rollback sequencing; the Go tests separately exercise
the real relay control socket and its persistent TCP listener on Linux.
"""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
RUNTIME = ROOT / 'root/usr/bin/fastacl252'
STUB = r'''#!/usr/bin/env python3
import json,os,pathlib,sys,time
r=pathlib.Path(os.environ['FASTACL_RUNTIME_DIR'])
name=pathlib.Path(sys.argv[0]).name
args=sys.argv[1:]
with (r/'events').open('a') as f:f.write(json.dumps([name,args])+'\n')
state=json.loads((r/'scenario.json').read_text())
if name=='uci':
 print('12525' if args[-1].endswith('.port') else '1')
elif name=='lua':
 if args[0]=='-e':
  path=os.environ.get('FASTACL_VALIDATE_EXE')
  if path:
   st=os.stat(path);print(st.st_ino,st.st_size,int(st.st_mtime),int(st.st_ctime))
  sys.exit(0)
 (r/'nft.next.rules').write_text('table inet fastacl252 {}\n')
 if args[-1]!='guard':
  (r/'router.next.dae').write_text(state.get('core','first'))
  (r/'dns.next.json').write_text(state.get('dns','first'))
elif name=='nft':
 if args[0]=='list':sys.exit(0 if (r/'firewall-loaded').exists() else 1)
 if args[0]=='-f':(r/'firewall-loaded').touch()
elif name in ['ss','netstat','ip']:
 print('tcp LISTEN 0 128 0.0.0.0:12553 0.0.0.0:*')
 print('tcp LISTEN 0 128 0.0.0.0:12525 0.0.0.0:*')
elif name=='dae':
 if args[0]=='validate':sys.exit(1 if state.get('invalid') else 0)
 if args[0]=='reload':sys.exit(1 if state.get('dae_reload_failure') else 0)
 if args[0]=='run':
  while True:time.sleep(1)
elif name=='fastacl252-dns':
 if '-check' in args:sys.exit(1 if state.get('invalid') else 0)
 if '-reload' in args:sys.exit(1 if state.get('dns_reload_failure') else 0)
 while True:time.sleep(1)
'''


@unittest.skipUnless(sys.platform.startswith('linux'), 'runtime process tests require Linux /proc')
class RuntimeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='fastacl-runtime-')
        self.root = Path(self.tmp.name)
        bindir = self.root / 'bin'
        bindir.mkdir()
        self.env = dict(os.environ, FASTACL_RUNTIME_DIR=str(self.root),
                        PATH=str(bindir) + os.pathsep + os.environ['PATH'],
                        FASTACL_CHECK_HELPER=str(ROOT / 'root/usr/libexec/fastacl252-check'))
        for name in ['uci', 'lua', 'nft', 'ss', 'netstat', 'ip', 'dae', 'fastacl252-dns']:
            path = bindir / name
            path.write_text(STUB, encoding='utf-8')
            path.chmod(0o755)
        self.scenario(core='first', dns='first')
        self.apply('cold-apply')

    def tearDown(self):
        subprocess.run(['sh', str(RUNTIME), 'cleanup'], env=self.env,
                       capture_output=True, timeout=15)
        # Also stop any surviving children when a regression made cleanup fail.
        for name in ['router.pid', 'dns.pid']:
            file = self.root / name
            if file.exists():
                try:
                    os.kill(int(file.read_text()), signal.SIGKILL)
                except (ProcessLookupError, ValueError):
                    pass
        self.tmp.cleanup()

    def scenario(self, **values):
        (self.root / 'scenario.json').write_text(json.dumps(values), encoding='utf-8')

    def apply(self, mode, success=True):
        result = subprocess.run(['sh', str(RUNTIME), mode], env=self.env,
                                capture_output=True, text=True, timeout=25)
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, 'failure was reported as success')
        return result

    def pids(self):
        return tuple(int((self.root / name).read_text()) for name in ['router.pid', 'dns.pid'])

    def test_hot_change_preserves_both_daemons(self):
        before = self.pids()
        self.scenario(core='second', dns='second')
        self.apply('hot-apply')
        self.assertEqual(self.pids(), before)
        self.assertEqual((self.root / 'router.dae').read_text(), 'second')
        self.assertEqual((self.root / 'dns.json').read_text(), 'second')
        events = [json.loads(line) for line in (self.root / 'events').read_text().splitlines()]
        self.assertTrue(any(name == 'dae' and args[0] == 'reload' for name, args in events))
        self.assertTrue(any(name == 'fastacl252-dns' and '-reload' in args for name, args in events))

    def test_rejected_dns_reload_keeps_pids_and_previous_config(self):
        before = self.pids()
        self.scenario(core='second', dns='second', dns_reload_failure=True)
        self.apply('hot-apply', success=False)
        self.assertEqual(self.pids(), before)
        self.assertEqual((self.root / 'dns.json').read_text(), 'first')
        self.assertEqual((self.root / 'router.dae').read_text(), 'first')

    def test_invalid_configuration_does_not_restart_apps(self):
        before = self.pids()
        self.scenario(core='invalid', dns='invalid', invalid=True)
        self.apply('hot-apply', success=False)
        self.assertEqual(self.pids(), before)
        self.assertEqual((self.root / 'router.dae').read_text(), 'first')

    def test_missing_private_table_repairs_without_restarting_apps(self):
        before = self.pids()
        (self.root / 'firewall-loaded').unlink()
        self.apply('ensure')
        self.assertEqual(self.pids(), before)
        self.assertTrue((self.root / 'firewall-loaded').exists())

    def test_invalid_startup_installs_guards_before_core_validation(self):
        self.apply('cleanup')
        (self.root / 'firewall-loaded').unlink(missing_ok=True)
        self.scenario(core='invalid', dns='invalid', invalid=True)
        self.apply('ensure', success=False)
        self.assertTrue((self.root / 'firewall-loaded').exists())
        self.assertFalse((self.root / 'router.pid').exists())
        self.assertFalse((self.root / 'dns.pid').exists())

    def test_dae_reload_failure_restarts_only_dae(self):
        before = self.pids()
        self.scenario(core='second', dns='second', dae_reload_failure=True)
        self.apply('hot-apply')
        after = self.pids()
        self.assertNotEqual(after[0], before[0])
        self.assertEqual(after[1], before[1])
        self.assertEqual((self.root / 'last-apply-mode').read_text().strip(), 'app-restart')


if __name__ == '__main__':
    unittest.main(verbosity=2)

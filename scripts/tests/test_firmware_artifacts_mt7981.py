from pathlib import Path
import importlib.util
from contextlib import redirect_stdout
import io
import json
import shutil
import subprocess
import tarfile
import tempfile
import unittest

script = Path(__file__).resolve().parents[1] / 'firmware-artifacts-mt7981.py'
spec = importlib.util.spec_from_file_location('artifacts', script)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


def status(extra=''):
    return ''.join(f'Package: {p}\nVersion: 2.5.6-r1\nStatus: install ok installed\n\n'
                   for p in sorted(m.REQUIRED)) + extra


class FakeFS:
    def __init__(self, packages=None):
        elf = bytearray(20)
        elf[:4] = b'\x7fELF'
        elf[18:20] = (183).to_bytes(2, 'little')
        self.files = {'/usr/lib/opkg/status': (packages or status()).encode(),
                      '/usr/libexec/mtwifi-station-bytes': bytes(elf),
                      '/usr/bin/fastacl252-dns': bytes(elf)}

    def get(self, path):
        data = self.files[path]
        class Entry:
            def open(self):
                return io.BytesIO(data)
        return Entry()


class ArtifactTests(unittest.TestCase):
    def test_status_ignores_removed_packages(self):
        p = m.installed(status('Package: gone\nVersion: 1\nStatus: deinstall ok config-files\n\n'))
        self.assertNotIn('gone', p)
        self.assertEqual(set(p), m.REQUIRED)

    def test_global_manifest_does_not_substitute_for_rootfs(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            target, out = root / 'target', root / 'output'
            target.mkdir(); out.mkdir()
            image = target / 'immortalwrt-xiaomi_mi-router-ax3000t-squashfs-sysupgrade.bin'
            with image.open('wb') as f:
                f.truncate(6 * 1024 * 1024)
            (target / 'immortalwrt-mediatek-filogic.manifest').write_text(status())
            self.assertTrue(m.verify(target, out, ['xiaomi_mi-router-ax3000t'], lambda _: FakeFS()))
            self.assertTrue((out / (image.name + '.manifest')).is_file())
            # A missing package in the actual image must fail even if the shared manifest lists it.
            broken = status().replace('Package: npc\n', 'Package: unrelated\n')
            with redirect_stdout(io.StringIO()):
                self.assertFalse(m.verify(target, out, ['xiaomi_mi-router-ax3000t'], lambda _: FakeFS(broken)))

    def test_variant_is_not_mistaken_for_base_device(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            image = root / 'immortalwrt-xiaomi_mi-router-ax3000t-ubootmod-squashfs-sysupgrade.itb'
            image.write_bytes(b'not a base-device image')
            self.assertFalse(m.verify(root, root, ['xiaomi_mi-router-ax3000t'], lambda _: FakeFS()))
            self.assertIn('missing sysupgrade', json.loads((root / 'verification.json').read_text())[0]['error'])

    def test_collection_is_repeatable_and_keeps_all_outputs(self):
        with tempfile.TemporaryDirectory() as d:
            target, out = Path(d) / 'target', Path(d) / 'upload'
            target.mkdir()
            (target / 'a-sysupgrade.bin').write_bytes(b'firmware')
            (target / 'target.manifest').write_text('npc - 0.26.10\n')
            m.collect(target, out)
            first = (out / 'SHA256SUMS').read_text()
            m.collect(target, out)
            self.assertEqual(first, (out / 'SHA256SUMS').read_text())
            self.assertEqual((out / 'a-sysupgrade.bin').read_bytes(), b'firmware')

    @unittest.skipUnless(shutil.which('mksquashfs'), 'mksquashfs not installed')
    def test_real_tar_and_fit_rootfs(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d); files = root / 'rootfs'
            p = files / 'usr/lib/opkg/status'; p.parent.mkdir(parents=True); p.write_text(status())
            squash = root / 'root.squashfs'
            subprocess.run(['mksquashfs', str(files), str(squash), '-noappend', '-no-progress', '-processors', '1'], check=True, stdout=subprocess.DEVNULL)
            tar = root / 'firmware.bin'
            with tarfile.open(tar, 'w') as archive:
                archive.add(squash, 'sysupgrade-test/root')
            fit = root / 'firmware.itb'; fit.write_bytes(b'FIT-prefix' + squash.read_bytes())
            for image in [tar, fit]:
                self.assertEqual(set(m.installed(m.rootfs(image).get('/usr/lib/opkg/status').open().read().decode())), m.REQUIRED)


if __name__ == '__main__':
    unittest.main()

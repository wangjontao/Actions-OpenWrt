"""Preserve outputs first; verify packages from each actual firmware rootfs."""
import argparse
import hashlib
import io
import json
import os
import re
from pathlib import Path
import shutil
import tarfile

REQUIRED = {'fastacl252', 'juliangtk-dae', 'kmod-mt_wifi', 'mtwifi-cfg',
            'luci-app-nps', 'npc', 'luci-app-autoreboot'}


def collect(target, output):
    output.mkdir(parents=True, exist_ok=True)
    files = sorted(p for p in target.iterdir() if p.is_file()) if target.is_dir() else []
    for p in files:
        print(f'{p.name} ({p.stat().st_size} bytes)')
        if p.suffix in {'.bin', '.itb', '.img', '.manifest', '.json', '.buildinfo'}:
            shutil.copy2(p, output / p.name)
    for name in ['.config', 'MT7981-FastACL255-final.config']:
        if Path(name).is_file():
            shutil.copy2(name, output / ('build.config' if name == '.config' else name))
    (output / 'BUILD.txt').write_text(
        'version=2.5.6\ncommit=' + os.environ.get('GITHUB_SHA', '') +
        '\ndevices=' + os.environ.get('MT7981_DEVICES', '') + '\n')
    sums = [f'{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.name}'
            for p in sorted(output.iterdir()) if p.is_file() and p.name != 'SHA256SUMS']
    (output / 'SHA256SUMS').write_text('\n'.join(sums) + '\n')


def rootfs(image):
    from dissect.squashfs import SquashFS
    try:
        archive = tarfile.open(image)
    except tarfile.ReadError:
        archive = None
    if archive:
        with archive:
            roots = [m for m in archive if m.isfile() and m.name.endswith('/root')]
            if len(roots) != 1:
                raise ValueError('sysupgrade tar must contain exactly one rootfs')
            data = archive.extractfile(roots[0]).read()
    else:
        data = image.read_bytes()
    offset = 0
    while True:
        offset = data.find(b'hsqs', offset)
        if offset < 0:
            raise ValueError('no readable SquashFS package database in firmware')
        try:
            fs = SquashFS(io.BytesIO(data[offset:]))
            fs.get('/usr/lib/opkg/status').open().read()
            return fs
        except Exception:
            offset += 4


def installed(text):
    packages = {}
    for block in text.replace('\r\n', '\n').split('\n\n'):
        fields = dict(line.split(': ', 1) for line in block.splitlines() if ': ' in line and not line.startswith(' '))
        if fields.get('Status', '').split()[-1:] == ['installed'] and fields.get('Package') and fields.get('Version'):
            packages[fields['Package']] = fields['Version']
    return packages


def verify(target, output, devices, reader=rootfs):
    report = []
    for dev in devices:
        pattern = re.compile(re.escape(dev) + r'-(?:squashfs|ext4)-sysupgrade(?:\.|-)')
        images = sorted(p for p in target.glob('*sysupgrade*') if p.is_file() and pattern.search(p.name))
        if not images:
            report.append({'device': dev, 'ok': False, 'error': 'missing sysupgrade image'})
            continue
        for image in images:
            item = {'device': dev, 'image': image.name, 'ok': False}
            try:
                if image.stat().st_size <= 5 * 1024 * 1024:
                    raise ValueError('sysupgrade image is smaller than 5 MiB')
                fs = reader(image)
                packages = installed(fs.get('/usr/lib/opkg/status').open().read().decode())
                missing = REQUIRED - packages.keys()
                if missing:
                    raise ValueError('missing installed packages: ' + ', '.join(sorted(missing)))
                if not packages['fastacl252'].startswith('2.5.6-'):
                    raise ValueError('unexpected FastACL version: ' + packages['fastacl252'])
                if 'kmod-mt7915e' in packages:
                    raise ValueError('competing mt76 driver installed')
                for path in ['/usr/libexec/mtwifi-station-bytes', '/usr/bin/fastacl252-dns']:
                    elf = fs.get(path).open().read(20)
                    if elf[:4] != b'\x7fELF' or int.from_bytes(elf[18:20], 'little') != 183:
                        raise ValueError('missing or incorrect ARM64 helper: ' + path)
                (output / (image.name + '.manifest')).write_text(
                    ''.join(f'{name} - {version}\n' for name, version in sorted(packages.items())))
                item.update(ok=True, package_count=len(packages))
                print('PASS:', dev, image.name, 'actual rootfs packages checked')
            except Exception as exc:
                item['error'] = str(exc)
                print('::error::' + dev + ': ' + str(exc))
            report.append(item)
    (output / 'verification.json').write_text(json.dumps(report, indent=2) + '\n')
    return bool(report) and all(row['ok'] for row in report)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('mode', choices=['collect', 'verify'])
    parser.add_argument('--target', type=Path, default=Path('bin/targets/mediatek/filogic'))
    parser.add_argument('--output', type=Path, default=Path('upload'))
    args = parser.parse_args()
    if args.mode == 'collect':
        collect(args.target, args.output)
    else:
        args.output.mkdir(parents=True, exist_ok=True)
        ok = verify(args.target, args.output, os.environ['MT7981_DEVICES'].split())
        collect(args.target, args.output)
        raise SystemExit(0 if ok else 1)

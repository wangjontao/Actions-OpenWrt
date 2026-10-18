"""Validate the actual Z8103AX sysupgrade rootfs before publishing a release."""
import io, pathlib, sys, tarfile
from dissect.squashfs import SquashFS
image=pathlib.Path(sys.argv[1]);domain=sys.argv[2];mode=sys.argv[3]
with tarfile.open(image) as archive:
    roots=[m for m in archive if m.name.endswith('/root')]
    assert len(roots)==1, 'Expected exactly one rootfs in sysupgrade tar'
    fs=SquashFS(io.BytesIO(archive.extractfile(roots[0]).read()))
    def read(path):
        try:return fs.get(path).open().read()
        except Exception as exc:raise AssertionError('Missing firmware payload: '+path) from exc
    checks={
      '/usr/lib/lua/luci/controller/juliang.lua':b'sampled_at',
      '/usr/lib/lua/luci/view/juliang/wireless.htm':b'jw-rate',
      '/usr/lib/lua/luci/view/juliang/dashboard.htm':b'bezierCurveTo',
      '/usr/libexec/install-juliang-dual-ip.sh':b'juliang-exit-ip',
      '/etc/uci-defaults/95-juliang-dual-ip':b'install-juliang-dual-ip.sh',
      '/etc/uci-defaults/91-z8103ax-mtwifi-leds':b'rax0',
      '/etc/init.d/nps-autokey':domain.encode(),
      '/etc/hotplug.d/iface/99-nps-autokey':b'/etc/init.d/nps restart',
      '/etc/juliang-build-version':b'V3',
    }
    for path,marker in checks.items():assert marker in read(path), 'Wrong payload: '+path
    elf=read('/usr/libexec/mtwifi-station-bytes');assert elf[:4]==b'\x7fELF' and int.from_bytes(elf[18:20],'little')==183, 'Wrong statistics helper architecture'
    assert b'respawn' in read('/etc/init.d/nps') if mode=='binary' else bool(read('/etc/init.d/nps'))
    if mode=='luci':assert read('/usr/lib/lua/luci/controller/nps.lua'), 'Missing LuCI NPS controller'
print('PASS actual sysupgrade rootfs:',image.name,domain,mode)

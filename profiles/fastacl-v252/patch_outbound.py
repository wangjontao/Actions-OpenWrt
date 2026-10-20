"""Patch the pinned vendored VLESS constructor before publishing its timer.

The delayed header writer must not observe addonsBytes while NewConn mutates it.
Keep this narrow and fail on an unrecognized dependency instead of editing a
shared Go module cache or accepting an unreviewed dependency upgrade.
"""
from pathlib import Path
import sys
p=Path(sys.argv[1])/'vendor/github.com/daeuniverse/outbound/protocol/vless/conn.go'
s=p.read_text(encoding='utf-8')
marker='// FastACL: publish delayed writer only after constructor initialization.'
if marker not in s:
 start=s.index('\tif metadata.Network == "tcp" && metadata.IsClient {')
 end=s.index('\tif metadata.Flow != "" {',start)
 delayed=s[start:end]
 assert 'time.AfterFunc' in delayed
 s=s[:start]+s[end:]
 ret=s.index('\treturn c, nil\n}',start)
 s=s[:ret]+'\t'+marker+'\n'+delayed+s[ret:]
 p.write_bytes(s.encode())
assert s.index('if metadata.Flow != ""')<s.index('time.AfterFunc')
print('Pinned VLESS constructor timer initialized after addons')

#!/usr/bin/env python3
"""Patch the MTWiFi source before its package is built, never a reference profile."""
from pathlib import Path
import sys

def patch(root,required=False):
    target=Path(root)/'package/mtk/applications/mtwifi-cfg/files/mtwifi-cfg/mtwifi_cfg'
    if not target.exists():
        if required:
            raise RuntimeError('Expected MTWiFi generator is missing')
        return 'native wireless driver; MTWiFi hook not applicable'
    source=target.read_text(encoding='utf-8')
    marker='-- JULIANG_HARDWARE_MAC_V1'
    if marker not in source:
        anchor='    local reinstall_wifidrv = false'
        if source.count(anchor)!=1:
            raise RuntimeError('Unsupported MTWiFi configuration generator; refusing an unverified firmware')
        source=source.replace(anchor,'    require("juliang_wifi_hardware").apply(cfg, dats) '+marker+'\n'+anchor)
        target.write_text(source,encoding='utf-8',newline='\n')
    return target

if __name__=='__main__':
    print('Hardware MAC hook:',patch('.',required='--required' in sys.argv))

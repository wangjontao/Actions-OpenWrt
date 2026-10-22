# FastACL V2.5.8 — fixed-entry switching

Based on the independent 2.5.7 current-mechanism branch. Existing WiFi/device node changes update the authenticated local relay slot mapping while generated dae and nft configurations remain unchanged for proxy-to-proxy assignment. Platform proxy rules, smart/custom IP routing, DNS splitting/blocking, WiFi controls, login/branding and the previous safety fixes are retained.

The real-router merge passed 90 compiler-invariance cases. A3 switching and restoration took 1.484 and 1.422 seconds while one real A2 HTTPS connection returned nine successful responses without reconnecting. dae/DNS PIDs and dae/nft configuration hashes remained unchanged. Phone testing confirmed A1/A2/A3 Internet access and uninterrupted A2 video while switching A3.

Primary DNS, proxy DNS and YouTube platform DNS mappings were checked after the merge. These are focused tests, not a guarantee that every platform/stream or hardware model has been validated. Create/delete WiFi and routing-policy changes can still modify topology or core configuration. Site-specific CAKE shaping is not enabled by this package snapshot.

No live nodes, subscriptions, WiFi passwords, device bindings, slot secrets or platform-map state are included in source. Firmware first boot enables fixed_exit=1 and reports version 2.5.8; secret material is generated locally.

## 2.5.8-r2 DHCP startup fix

Pin each owned WiFi bridge explicitly in its fw4 zone, in addition to the logical network reference. This prevents early firewall loads from omitting the DHCP/DNS zone before netifd reports the managed interface up. An idempotent first-boot migration updates only matching FastACL-owned zones, preserving primary and unrelated networks and existing device entries. Live Philips HY3000 testing recovered A1/A2 DHCP leases and phone Internet access; no WiFi or dae/DNS restart was required. Added migration ownership/idempotence regression coverage.

## Bundled split-data repair

Ship both cn-ipv4.txt (5,498 APNIC-derived CN IPv4 ranges, 2026-10-20 snapshot) and cn-domains.txt (109,795 suffixes from the previously validated dnsmasq-china-list snapshot). The previous source checkpoint omitted these runtime data assets, causing smart IP routing to fail and preventing domestic DNS domain splitting. Pinned SHA-256 metadata, format/count and actual smart-policy compilation tests are included. Package installation rejects missing/empty data files. Live policy compilation and real dae/DNS validators passed after installing the files without changing saved settings or restarting services.

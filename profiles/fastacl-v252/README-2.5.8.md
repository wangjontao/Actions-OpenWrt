# FastACL V2.5.8 — fixed-entry switching

Based on the independent 2.5.7 current-mechanism branch. Existing WiFi/device node changes update the authenticated local relay slot mapping while generated dae and nft configurations remain unchanged for proxy-to-proxy assignment. Platform proxy rules, smart/custom IP routing, DNS splitting/blocking, WiFi controls, login/branding and the previous safety fixes are retained.

The real-router merge passed 90 compiler-invariance cases. A3 switching and restoration took 1.484 and 1.422 seconds while one real A2 HTTPS connection returned nine successful responses without reconnecting. dae/DNS PIDs and dae/nft configuration hashes remained unchanged. Phone testing confirmed A1/A2/A3 Internet access and uninterrupted A2 video while switching A3.

Primary DNS, proxy DNS and YouTube platform DNS mappings were checked after the merge. These are focused tests, not a guarantee that every platform/stream or hardware model has been validated. Create/delete WiFi and routing-policy changes can still modify topology or core configuration. Site-specific CAKE shaping is not enabled by this package snapshot.

No live nodes, subscriptions, WiFi passwords, device bindings, slot secrets or platform-map state are included in source. Firmware first boot enables fixed_exit=1 and reports version 2.5.8; secret material is generated locally.

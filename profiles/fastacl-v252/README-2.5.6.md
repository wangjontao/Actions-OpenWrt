# FastACL 2.5.6

MT7981 uses stable authenticated loopback SOCKS entries in dae and atomically replaces per-device/WiFi exit mappings in the existing DNS helper. Switching an existing target keeps the dae process, eBPF/network/WiFi configuration and firewall rules unchanged; only sessions belonging to a changed exit are disconnected. TCP and UDP are supported. Unknown slots and failed authentication are rejected. The router generates its own root-only secret; no private router configuration is included.

New WiFi or first-time device topology initialization can still require application reinitialization. Existing targets use mapping updates. Legacy mode remains available with fixed_exit=0. CI checks compiler/firewall invariance and TCP/UDP session isolation.

Version labels are 2.5.6; the LuCI/Argon distribution footer is hidden. Build dispatch remains a separate operation.

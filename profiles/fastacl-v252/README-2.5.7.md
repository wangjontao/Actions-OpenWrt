# FastACL V2.5.7 — current mechanism checkpoint

This branch freezes the current tested-router implementation. It is independent of 2.5.6 and does not introduce the fixed-entry switching design.

## Runtime mechanism

A shared dae core routes managed WiFi subnets and main-LAN devices. Applying a different exit generates and validates application configuration, updates the FastACL nft rules, reloads DNS policy, and may reload dae. A failed dae reload may fall back to a dae-only restart. Other WiFi associations stay up, but their traffic sessions can be affected by a shared-core reload. Normal assignment does not reload the system network or WiFi services.

The authenticated loopback SOCKS listener in this version serves platform-selected traffic; it is not the general fixed-entry switching mechanism from 2.5.6.

## Included live changes

- Domestic-IP direct routing, foreign proxy routing, custom IPv4 rules and DNS domain blocking, collapsible editors and instructions.
- TikTok, Facebook, Instagram, YouTube and Shopee proxy selection. Recognized platform DNS and mapped connections use the selected exit without direct fallback. Platform transport is marked AF41 for CAKE priority.
- Root-only generated listener secret and scoped platform mappings; no device secrets or live subscription data are shipped.
- Bulk WiFi deletion/hide/restore, per-WiFi visibility, guarded clear-all preserving primary WiFi, purple deletion text and white visibility text.
- Immediate WiFi-create feedback, elapsed timer, completion/failure feedback and duplicate-operation controls.
- Edit lock uses close-on-exec and explicit unlock; node import parses before the write lock and retries explicit pre-commit busy responses for at most 60 seconds.
- Node-only validation does not create an unauthenticated platform listener.
- Main-LAN MAC/address guard is scoped to the main subnet so roaming to managed WiFi is not wrongly blocked.
- System card displays JuLiangTK OS V2; footer attribution is hidden through the theme hook; LuCI login does not prefill root; the generic jontao owner login first-boot hook is included.

## Configuration boundaries

Existing firmware defaults of 9 additional 5GHz WiFi and 3 additional 2.4GHz WiFi are retained. The current JDCloud test router has a local 14/8 override; this override and all SSIDs/passwords/device bindings are intentionally not copied into firmware defaults.

CAKE/SQM dependencies are included. The test router uses 45/450 Mbps shaping for a nominal 50/500 Mbps line, with upload diffserv4 and download besteffort. Those site-specific SQM settings and WAN interface are not exported or enabled by this checkpoint. AF41 marking alone is not a guarantee of smooth streaming; unrecognized app encrypted DNS/direct-IP traffic is outside the preset coverage.

## Validation and build status

Live checks covered lock descriptor inheritance, concurrent busy responses, import validation, rule compilation, UI retry/progress paths, and platform DNS/proxy samples. Firmware builds and regression on all MT7981/AX6000 devices have not been run for this checkpoint.

Inherited 2.5.6 workflows/tests remain historical and include fixed-entry-specific expectations; they are not evidence that this branch has passed a firmware build. No workflow is dispatched by this source synchronization. Adapt the build validation gates to this mechanism before compiling this branch.

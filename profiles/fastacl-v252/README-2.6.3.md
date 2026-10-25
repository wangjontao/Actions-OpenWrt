# FastACL V2.6.3

V2.6.3 adds a signed, model-aware online firmware updater to LuCI.

## Online upgrade

- Manual update checks with stable and beta channels.
- The updater downloads only the exact `board_name` image published for the device.
- The signed manifest is verified with the Ed25519 public key embedded in firmware.
- The firmware SHA-256 and `sysupgrade -T` result are checked before flashing.
- Configuration is preserved across a normal 2.6.x sysupgrade.
- Existing 2.6.1/2.6.2 installations are marked provisioned so WiFi, LAN and SSH settings are not replaced during upgrade.
- The LuCI page tracks checking, downloading, verifying and installing states.
- After reboot the page confirms whether the target version is running.
- Factory images and unlisted models are never accepted for online upgrade.

## Scope

- First online-upgrade release supports the 20 MT7981 models and the CLX S20L, CLX S20P and JDCloud RE-CP-03 AX6000.
- Redmi AX6000 NMBM 110MiB remains excluded until its partition layout can be identified safely at runtime.
- Single-rootfs devices have no automatic firmware rollback. Configuration is backed up by the normal sysupgrade flow.

## Release trust

- Release manifests are hosted at `https://up.juliangtk.top:8443/<channel>.json`.
- Firmware is hosted under immutable versioned paths.
- The signing private key exists only in the protected GitHub `release` environment.
- The device embeds only the public verification key.

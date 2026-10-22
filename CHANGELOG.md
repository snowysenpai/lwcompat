# Changelog

## Unreleased

- One log file per launch under `logs/sessions/`; `logs/lwcompat.log` is a symlink to the
  newest session, so the GUI no longer re-reads the whole history on every refresh.
  The last 10 sessions are kept (`LWCOMPAT_KEEP_LOGS`); the old single log is archived once.
- LWCompat, updater and manifest-fetch log lines carry a time stamp.
- Added `lwcompat-doctor`, a read-only, shareable diagnostics report.
- Desktop notifications for fatal launch errors, game updates and natively fetched manifests.
- Identified the root cause of the launcher's 5-second `error decoding response body` timeouts
  (Wine < 11.6 `SECBUFFER_MISSING` size bug, upstream commit `35b1e7eb`) and added
  `tools/wine-schannel-repro/` to test any Proton build for it. GE-Proton11-11 is not affected.
- Added `src/fetch_proton.sh`: downloads an official GE-Proton release from GitHub, verifies
  its SHA-512 and archive paths, and installs it next to existing builds. The installer
  offers it when no Proton is found (`LWCOMPAT_FETCH_PROTON=1|0`) and now also detects
  `GE-Proton*` directories.
- `uninstall.sh` now also removes `lwcompat-update` (it removed `lwcompat-overlay` twice).

## 0.3.0 - 2026-10-22

Version numbers are now taken from `VERSION` (launcher log, installer) and match the
GUI crate. Intermediate 0.2.x builds were not tagged.

### Launcher / updates
- Fixed endless `error decoding response body ... operation timed out` loops when a new
  manifest is published. Wine's schannel stalls on the final TLS record of the signed
  manifest body even though the CDN delivers it completely; LWCompat now fetches
  `manifest/<channel>/manifests/<version>.json` and its `.sig` natively
  (`fetch_signed_manifest.py`), validates size, Content-MD5, version, channel and
  signature length, backs up the old manifest and lets the launcher verify the signature.
- `update.sh` uses the same native manifest fetch in phase 1.
- Fixed `update.sh` aborting in cleanup on unbound `UPDATE_SUCCEEDED` /
  `FAST_CACHE_WAS_ENABLED`, which left Fast Asset Cache disabled after updates.
- Game/launcher process checks match process names instead of command lines,
  so unrelated commands mentioning the game path are no longer treated as a running game.

### Custom Vulkan HUD
- Added the HUD layer sources (`hud-spike/`) with Dear ImGui v1.91.9b as a git submodule;
  a clean build is byte-identical to the previously installed layer.
- The installer builds and installs the layer and writes a manifest with a relative
  `library_path`. The installed manifest had been empty since 2026-09-24, so the layer
  was silently never loaded.
- HUD is optional (`LWCOMPAT_CUSTOM_HUD=1`, default off) and a missing or invalid layer
  no longer aborts the launch.
- `network_feed.py` (formerly the untracked `mangohud_net.py`) is installed by the installer.

### Fast Asset Cache
- The image now binds the whole launcher `Cache` directory instead of only
  `Cache/AssetBundles`. The launcher downloads into `Cache/AssetBundles.Temp` and renames
  into `Cache/AssetBundles`; across filesystems that rename fails
  (`ERROR_NOT_SAME_DEVICE`), which is why updates previously had to disable the cache.
- Updates now run with the cache active: no root prompt, no rsync refresh.
  The disable/refresh path remains as a fallback on bundle move failures and for the
  legacy layout.
- Existing images are migrated in place on service start (a rename inside the image,
  no copy). `lwcompat-fast-cache status` shows the active `Layout`.

## 0.1.0 - 2026-09-21

Initial public prototype release.

- Added fresh-per-session native bridge lifecycle.
- Added CDN bridge on `127.0.0.1:18080`.
- Added version/table API bridge on `127.0.0.1:18081`.
- Added automatic `manifest.json` patching.
- Added Faugus / UMU + GE-Proton launcher integration.
- Added single-instance launch lock.
- Added per-user installer and uninstaller.
- Added KDE / freedesktop desktop entry.
- Added optional local extraction of the official game icon.
- Added logs and troubleshooting documentation.

### Fast Asset Cache
- Implemented optional ext4 casefold-backed AssetBundles cache.
- Added automatic first-time migration of existing AssetBundles.
- Added persistent systemd mounting with transparent Btrfs fallback.
- Added reusable cache support across LWCompat uninstall/reinstall cycles.
- Added `lwcompat-fast-cache status|enable|disable|toggle`.
- Added safe uninstall behavior that preserves the Fast Asset Cache by default.
- Added `--purge-fast-cache` for complete removal.
- Measured directory enumeration reduction from ~104k to ~15k `getdents64` calls during startup testing.
- Observed warm startup reduction from ~53 seconds to approximately 35–40 seconds on the test system.

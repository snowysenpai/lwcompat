# Changelog

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

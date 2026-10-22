# Architecture

The official launcher stays authoritative for game update logic, file verification and
launching. LWCompat supervises it from the outside: it reads `Launcher.log`, works around
known Wine problems, and never patches the launcher binary or its signed manifest.

## Components

### `start.sh`

Desktop-facing entry point. Holds a `flock` lock so repeated clicks cannot start concurrent
sessions, writes one log per session under `logs/sessions/` and points `logs/lwcompat.log`
at the newest one.

### `lwcompat.sh`

Session supervisor. It:

1. loads installation paths from `config.sh` and per-user settings;
2. configures shader caches, DXVK overlays and the optional custom Vulkan HUD;
3. launches the official launcher through UMU without any proxy;
4. classifies `Launcher.log` with `launcher_log.sh` and reacts:
   - `started`: wait until the game exits;
   - `manifest-stall`: fetch the signed remote manifest natively, retry;
   - `transient`: retry (up to 20 attempts);
   - `update`: run `update.sh` once, then retry;
5. sends desktop notifications for errors and updates.

### `launcher_log.sh`

The single classification of launcher states, shared with `lwcompat-doctor` and covered
by `tests/test_launcher_log.sh`.

### `fetch_signed_manifest.py`

Downloads `<manifest_url>/manifest/<channel>/manifests/<version>.json` and its `.sig` on the
host, validates size, Content-MD5, version, channel and signature length, backs up the old
manifest and installs the new one atomically. The launcher verifies the signature itself.
Needed because Wine before 11.6 stalls on this download (see
`tools/wine-schannel-repro/`).

### `update.sh`

Updater for real game updates: acquires the current signed manifest through the launcher
via the `CONNECT` relay (`connect_proxy.py`, `127.0.0.1:18083`), installs changed client
files natively with `bootstrap_client.py`, then lets the launcher sync resources without
any proxy. When `lwcompat.sh` runs it (`LWCOMPAT_UPDATE_HANDOFF=1`) and the launcher starts
the game at the end of that sync, the game is kept and `update.sh` exits with 10 instead of
killing it for a second launch. `LWCOMPAT_UPDATE_RELAY=1` restores the relayed resource
sync. With the Cache-level Fast Asset Cache it runs with the cache active.

### `bootstrap.sh` / `bundle_proxy.py`

First-install path only: downloads the official `LastWarDownloader.exe` from lastwar.com
into a new prefix and bridges bundle/API traffic through `127.0.0.1:18080/18081` while it
runs.

### Fast Asset Cache

`fast_asset_cache.sh` (root helper, systemd service) bind-mounts the `Cache` directory from
an ext4 casefold image over the launcher's `Cache` directory so Wine's case-insensitive
lookups over ~22k bundle files are fast and `AssetBundles.Temp -> AssetBundles` renames stay
on one mount. `fast_asset_cache_ctl.sh` (`lwcompat-fast-cache`) controls it.

### Supporting tools

- `doctor.sh` (`lwcompat-doctor`): read-only, shareable diagnostics.
- `fetch_proton.sh`: downloads and verifies official GE-Proton releases.
- `network_feed.py` + `hud-spike/`: optional custom Vulkan HUD.

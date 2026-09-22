# LWCompat

A lightweight Linux compatibility layer for **Last War: Survival Game**.

LWCompat keeps the official Windows launcher and game intact. It works around launcher networking issues observed under Wine/Proton by routing the launcher's bundle CDN and version/table API traffic through a small native Linux HTTP-to-HTTPS bridge.

It also includes optional performance optimizations specifically discovered while profiling Last War under Wine/Proton.

> **Status:** early community release / proof-of-concept validated primarily on Fedora KDE with Faugus Launcher, UMU and GE-Proton.

## What it does

LWCompat currently:

- launches the existing official `LastWarLauncher.exe` through Faugus/UMU + GE-Proton;
- patches only two launcher manifest values at launch time;
- starts a local native bridge on `127.0.0.1`;
- proxies bundle/CDN traffic through port `18080`;
- proxies version/table API traffic through port `18081`;
- keeps TLS handling on the Linux side instead of inside the Windows launcher;
- starts a fresh bridge for every game session;
- prevents accidental double-launches;
- configures persistent DXVK and driver shader caches;
- supports an optional casefold-backed **Fast Asset Cache**;
- creates a desktop menu entry;
- attempts to extract the official icon locally from installed game files;
- includes a separate Rust GUI frontend while keeping the working Bash/Python compatibility engine intact.

It **does not** redistribute Last War binaries, assets, Proton builds, Faugus components, or proprietary game artwork.

## Current architecture

```text
Last War (LWCompat)
        |
        v
start.sh
        |
        v
lwcompat.sh
        |
        +--> patch manifest.json
        |      bundle_url     -> http://127.0.0.1:18080/
        |      bundle_ver_url -> http://127.0.0.1:18081
        |
        +--> bundle_proxy.py
        |      127.0.0.1:18080 -> https://lastwar-cdn.akamaized.net/hotupdate
        |      127.0.0.1:18081 -> https://lastwar-serverlist-cf.lastwarapp.net
        |
        +--> performance/cache configuration
        |
        +--> UMU / GE-Proton
               |
               v
        LastWarLauncher.exe
               |
               v
            LastWar.exe
```

Both native bridge listeners bind to `127.0.0.1` only.

## Requirements

LWCompat currently expects an already-working Wine/Proton installation of the official Last War PC launcher.

Core requirements:

- official Last War PC launcher installed in a Wine/Proton prefix;
- Faugus Launcher / `umu-run`;
- GE-Proton;
- Python 3;
- Bash;
- `flock` from `util-linux`;
- `pgrep` / `pkill` from `procps`.

Optional, for notifications and automatic icon extraction:

- `libnotify` / `notify-send`;
- `icoutils` (`wrestool`, `icotool`);
- ImageMagick (`identify`).

The optional **Fast Asset Cache** additionally uses:

- `rsync`;
- `mkfs.ext4`;
- `chattr` / `lsattr`;
- loop mounts;
- systemd;
- `sudo`.

### Fedora

```bash
sudo dnf install python3 util-linux procps-ng libnotify icoutils ImageMagick rsync e2fsprogs
```

### Debian / Ubuntu

```bash
sudo apt install python3 util-linux procps libnotify-bin icoutils imagemagick rsync e2fsprogs
```

## Install

Clone the repository and run:

```bash
git clone https://github.com/snowysenpai/lwcompat.git
cd lwcompat

chmod +x install.sh uninstall.sh
./install.sh
```

The installer tries to detect:

- the Last War installation directory;
- the Wine prefix;
- Faugus `umu-run`;
- GE-Proton.

The common tested game path is:

```text
~/Games/LastWar/drive_c/users/steamuser/AppData/Local/FunFly/Last War-Survival Game
```

If an AssetBundles cache is detected, the installer also offers to configure the optional **Fast Asset Cache**.

After installation, launch **Last War (LWCompat)** from the desktop application menu, or run:

```bash
~/.local/bin/lwcompat
```

## Custom paths

If automatic detection fails, provide paths when running the installer:

```bash
LWCOMPAT_GAME_DIR="$HOME/path/to/Last War-Survival Game" \
LWCOMPAT_UMU="$HOME/path/to/umu-run" \
LWCOMPAT_PROTON="$HOME/path/to/Proton-GE" \
./install.sh
```

The Wine prefix is derived automatically from the game directory when the game lives inside a standard `drive_c` tree.

Fast Asset Cache can also be explicitly enabled or skipped during installation:

```bash
LWCOMPAT_FAST_CACHE=1 ./install.sh
```

or:

```bash
LWCOMPAT_FAST_CACHE=0 ./install.sh
```

## Fast Asset Cache

### Why it exists

Performance profiling uncovered a significant Wine filesystem lookup bottleneck in Last War's AssetBundles cache.

The game stores more than 22,000 bundle files in one directory:

```text
Cache/AssetBundles
├── ~6.0 GB
└── 22,197+ bundle files
```

On the tested case-sensitive Btrfs filesystem, Wine repeatedly enumerated this directory while resolving Windows-style case-insensitive filenames.

Profiling showed the startup path spending significant CPU time in:

```text
NtQueryFullAttributesFile
└── get_nt_and_unix_names
    └── lookup_unix_name
        └── find_file_in_dir
            └── getdents64
                └── btrfs_real_readdir
```

During a 20-second startup trace:

```text
Btrfs / normal AssetBundles directory

AssetBundles getdents64 calls : 88,503
Total getdents64 calls        : 104,676
```

With the AssetBundles directory placed on an ext4 filesystem using native casefold support:

```text
ext4 casefold AssetBundles

AssetBundles getdents64 calls : 0
Total getdents64 calls        : 15,818
```

This reduced total directory-enumeration calls by roughly **85%** in the test.

### Startup measurements

Warm-cache startup measurements on the test system:

```text
Btrfs baseline

Base ready         : ~53.0 s
LastWar.exe → base : ~45.7 s
```

With Fast Asset Cache:

```text
Base ready

40.2 s
36.3 s
34.8 s
```

and:

```text
LastWar.exe → base

31.2 s
28.4 s
26.7 s
```

These measurements are hardware- and cache-state-dependent and should not be treated as guaranteed performance numbers.

They demonstrate the filesystem bottleneck and the improvement observed on the tested system.

### How it works

LWCompat creates a sparse ext4 filesystem image with casefold support.

```text
Original AssetBundles
        |
        | one-time migration
        v
ext4 casefold image
        |
        v
/mnt/lwcompat-assetbundles
        |
        | bind mount
        v
Game Cache/AssetBundles
```

The original host filesystem directory is left in place underneath the bind mount.

If Fast Asset Cache is disabled, the original directory becomes visible again and acts as a fallback.

The multi-gigabyte cache is **not copied on every launch**.

### Managing Fast Asset Cache

Check status:

```bash
lwcompat-fast-cache status
```

Enable:

```bash
lwcompat-fast-cache enable
```

Disable:

```bash
lwcompat-fast-cache disable
```

Toggle:

```bash
lwcompat-fast-cache toggle
```

Example active state:

```text
=== LWCompat Fast Asset Cache ===
Enabled : yes
Service : yes
FS      : ext4
Source  : /dev/loop0[/AssetBundles]
Status  : ACTIVE
```

Example fallback state:

```text
Enabled : no
Service : no
FS      : btrfs
Status  : DISABLED / FALLBACK
```

Fast Asset Cache cannot be enabled or disabled while Last War or its launcher is running.

### Persistent mounting

Fast Asset Cache uses:

```text
lwcompat-fast-asset-cache.service
```

The systemd service mounts the ext4 image and bind-mounts its `AssetBundles` directory into the location expected by the game.

Once configured, normal game launches do not require sudo.

## Shader caches

LWCompat keeps graphics caches in:

```text
~/.cache/lwcompat/
├── dxvk/
├── nvidia/
└── mesa/
```

The launcher currently configures:

```text
DXVK_STATE_CACHE_PATH
DXVK_SHADER_CACHE_PATH
__GL_SHADER_DISK_CACHE
__GL_SHADER_DISK_CACHE_PATH
MESA_SHADER_CACHE_DIR
```

Unsupported driver-specific variables are simply ignored by the active graphics stack.

## Installed files

The normal per-user installation lives under:

```text
~/.local/share/lwcompat/
├── bundle_proxy.py
├── config.sh
├── lwcompat.sh
├── start.sh
├── fast_asset_cache.sh
├── fast_asset_cache_ctl.sh
├── setup_fast_asset_cache.sh
├── lwcompat-fast-asset-cache.service
├── fast-cache/
├── backups/
└── logs/
```

User commands:

```text
~/.local/bin/lwcompat
~/.local/bin/lwcompat-fast-cache
```

Desktop integration:

```text
~/.local/share/applications/lwcompat.desktop
~/.local/share/icons/lastwar-lwcompat.png
```

When Fast Asset Cache is enabled, a small amount of system-level configuration is also installed:

```text
/etc/lwcompat/fast-asset-cache.conf
/etc/systemd/system/lwcompat-fast-asset-cache.service
/usr/local/libexec/lwcompat-fast-asset-cache
```

## Logs

Main launcher log:

```bash
tail -f ~/.local/share/lwcompat/logs/lwcompat.log
```

Bridge log:

```bash
tail -f ~/.local/share/lwcompat/logs/proxy.log
```

A healthy version API request looks similar to:

```text
[API] GET /gameservice/getlsu3dversion.php?...
[API] <- HTTP 200
[API] streamed=...
```

A healthy Fast Asset Cache launch reports:

```text
[LWCompat] Fast Asset Cache: ACTIVE (/dev/loop0[/AssetBundles])
```

## Troubleshooting

### `Checking data table` -> `error decoding response body`

Check that both bridge ports are listening:

```bash
ss -ltn '( sport = :18080 or sport = :18081 )'
```

Both:

```text
127.0.0.1:18080
127.0.0.1:18081
```

should be present while LWCompat is running.

Then inspect:

```bash
tail -n 100 ~/.local/share/lwcompat/logs/proxy.log
```

### Check Fast Asset Cache

Run:

```bash
lwcompat-fast-cache status
```

or:

```bash
findmnt -T "$HOME/Games/LastWar/drive_c/FunFly/Last War-Survival Game/Cache/AssetBundles"
```

When active, the target should resolve to an ext4 source similar to:

```text
/dev/loop0[/AssetBundles]
```

When disabled, the original host filesystem should be visible.

### Wrong game / Proton path

Edit:

```text
~/.local/share/lwcompat/config.sh
```

or rerun the installer with the environment variables shown above.

### Desktop icon is generic

LWCompat does not ship proprietary game artwork.

The installer attempts to extract the icon from the local official game installation when `wrestool`, `icotool`, and optionally `identify` are available.

## Uninstall

Normal uninstall:

```bash
./uninstall.sh
```

The uninstaller:

- restores the official launcher bundle endpoints;
- stops and removes LWCompat system integration;
- removes launcher files and desktop integration;
- preserves the Fast Asset Cache image by default.

This allows the existing cache to be reused without migrating the AssetBundles again if LWCompat is reinstalled later.

To remove everything including the Fast Asset Cache image:

```bash
./uninstall.sh --purge-fast-cache
```

To explicitly preserve the cache:

```bash
./uninstall.sh --keep-fast-cache
```

## Known limitations

- LWCompat does **not** install the official game or bootstrap a completely fresh Last War prefix.
- It expects an existing official launcher installation and an existing Faugus/UMU + GE-Proton setup.
- A future game or launcher update may change endpoints, manifest structure, or filesystem behavior.
- The initial official launcher manifest/version bootstrap is not handled by LWCompat yet.
- Fast Asset Cache currently depends on Linux ext4 casefold, loop mounts, systemd and elevated privileges during setup or state changes.
- Performance measurements currently come from a limited test environment and need validation across more hardware and distributions.
- The Rust GUI is still separate from the Bash/Python compatibility engine.

## Why this exists

In the tested environment, the official launcher could successfully establish HTTPS connections under Wine/Proton but intermittently timed out while decoding response bodies.

Native Linux HTTP clients handled the same endpoints correctly.

LWCompat therefore keeps the official launcher logic but moves the problematic HTTPS body handling to a native Linux bridge.

Further profiling also revealed that Last War's very large flat AssetBundles directory caused expensive case-insensitive lookup behavior under Wine on the tested filesystem.

Fast Asset Cache addresses that bottleneck without modifying game binaries.

## Security model

- Local bridge listeners bind only to `127.0.0.1`.
- Upstream hosts are hard-coded to the official Last War CDN and version service used by the tested launcher.
- LWCompat does not proxy arbitrary hosts.
- The Windows launcher still controls its own manifests, file selection, verification, updates and game launch flow.
- Fast Asset Cache contains game cache data only and is mounted locally.
- Elevated privileges are used only for operations that require system mounts/service configuration.

## Legal / trademark notice

LWCompat is an unofficial community project and is not affiliated with, endorsed by, or sponsored by FUNFLY, FirstFun, or the Last War: Survival Game developers/publishers.

`Last War`, its logos, game files, launcher, assets and related trademarks belong to their respective owners.

This repository intentionally does not include proprietary game binaries or artwork.

## License

LWCompat's own scripts and source code are licensed under the MIT License.

See [LICENSE](LICENSE).

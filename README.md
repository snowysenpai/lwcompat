# LWCompat

A lightweight Linux compatibility wrapper for **Last War: Survival Game**.

LWCompat keeps the official Windows launcher and game intact. It works around launcher networking issues observed under Wine/Proton by routing the launcher's bundle CDN and version/table API traffic through a small native Linux HTTP-to-HTTPS bridge.

> **Status:** early community release / proof-of-concept that has been validated on Fedora KDE with Faugus Launcher and GE-Proton.

## What it does

LWCompat currently:

- launches the existing official `LastWarLauncher.exe` through your current Faugus/UMU + GE-Proton setup;
- patches only two launcher manifest values at launch time;
- starts a local native bridge on `127.0.0.1`;
- proxies bundle/CDN traffic through port `18080`;
- proxies version/table API traffic through port `18081`;
- keeps TLS on the Linux side instead of inside the Windows launcher;
- starts a fresh bridge for every game session;
- prevents accidental double-launches;
- creates a desktop menu entry;
- attempts to extract the official icon locally from your installed game files.

It **does not** redistribute any Last War binaries, assets, Proton builds, or Faugus components.

## Current architecture

```text
Last War (LWCompat) desktop entry
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
        +--> UMU / GE-Proton
               |
               v
        LastWarLauncher.exe
               |
               v
            LastWar.exe
```

Both bridge listeners bind to `127.0.0.1` only.

## Requirements

This release intentionally preserves the already-working compatibility stack. Before installing LWCompat, you should already have:

- the official Last War PC launcher installed in a Wine/Proton prefix;
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

### Fedora

```bash
sudo dnf install python3 util-linux procps-ng libnotify icoutils ImageMagick
```

### Debian / Ubuntu

```bash
sudo apt install python3 util-linux procps libnotify-bin icoutils imagemagick
```

## Install

Download or clone the repository, then run:

```bash
chmod +x install.sh uninstall.sh
./install.sh
```

The installer will try to detect:

- the Last War installation directory;
- the Wine prefix;
- Faugus `umu-run`;
- GE-Proton.

The common tested game path is:

```text
~/Games/LastWar/drive_c/users/steamuser/AppData/Local/FunFly/Last War-Survival Game
```

After installation, launch **Last War (LWCompat)** from your desktop application menu, or run:

```bash
~/.local/bin/lwcompat
```

## Custom paths

If automatic detection fails, pass paths when running the installer:

```bash
LWCOMPAT_GAME_DIR="$HOME/path/to/Last War-Survival Game" \
LWCOMPAT_UMU="$HOME/path/to/umu-run" \
LWCOMPAT_PROTON="$HOME/path/to/Proton-GE" \
./install.sh
```

The Wine prefix is derived automatically from the game directory when the game lives inside a standard `drive_c` tree.

## Installed files

LWCompat is installed per-user and does not require root:

```text
~/.local/share/lwcompat/
├── bundle_proxy.py
├── config.sh
├── lwcompat.sh
├── start.sh
├── backups/
└── logs/

~/.local/bin/lwcompat
~/.local/share/applications/lwcompat.desktop
~/.local/share/icons/lastwar-lwcompat.png   # when icon extraction succeeds
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

## Troubleshooting

### `Checking data table` -> `error decoding response body`

Check that both bridge ports are listening:

```bash
ss -ltn '( sport = :18080 or sport = :18081 )'
```

Both `127.0.0.1:18080` and `127.0.0.1:18081` should be present while LWCompat is running.

Then inspect:

```bash
tail -n 100 ~/.local/share/lwcompat/logs/proxy.log
```

### Wrong game / Proton path

Edit:

```text
~/.local/share/lwcompat/config.sh
```

or re-run the installer with the environment variables shown above.

### Desktop icon is generic

LWCompat does not ship proprietary game artwork. The installer attempts to extract the icon from your local official game installation when `wrestool`, `icotool`, and optionally `identify` are available.

## Uninstall

```bash
./uninstall.sh
```

The uninstaller restores the official bundle endpoints in the current `manifest.json`, removes the desktop entry, launcher files, logs, and the extracted local icon.

## Known limitations

- This version does **not** install the official game or bootstrap a completely fresh Last War prefix.
- It expects an existing official launcher installation and an existing Faugus/UMU + GE-Proton setup.
- A future game/launcher update may change endpoints or manifest structure.
- The initial official launcher manifest/version bootstrap is not handled by LWCompat yet; this release is designed around an already-installed launcher.
- The UI is currently the desktop menu entry plus the official launcher. A Rust GUI is planned separately.

## Why this exists

In the tested environment, the official launcher could successfully establish HTTPS connections under Wine/Proton but intermittently timed out while decoding response bodies. Native Linux HTTP clients handled the same endpoints correctly. LWCompat therefore keeps the official launcher logic but moves the problematic HTTPS body handling to a native Linux bridge.

## Security model

- Local listeners bind only to `127.0.0.1`.
- Upstream hosts are hard-coded to the official Last War CDN and version service used by the tested launcher.
- LWCompat does not proxy arbitrary hosts.
- The Windows launcher still controls its own manifests, file selection, verification, updates, and game launch flow.

## Legal / trademark notice

LWCompat is an unofficial community project and is not affiliated with, endorsed by, or sponsored by FUNFLY, FirstFun, or the Last War: Survival Game developers/publishers.

`Last War`, its logos, game files, launcher, assets, and related trademarks belong to their respective owners. This repository intentionally does not include proprietary game binaries or artwork.

## License

LWCompat's own scripts and source code are licensed under the MIT License. See [LICENSE](LICENSE).

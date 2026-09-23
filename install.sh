#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$HOME/.local/share/lwcompat"
BIN_DIR="$HOME/.local/bin"
APPS_DIR="$HOME/.local/share/applications"
ICONS_DIR="$HOME/.local/share/icons"
BACKUP_DIR="$APP_DIR/backups"

GUI_INSTALL="$APP_DIR/lwcompat-gui"
GUI_SOURCE="$ROOT_DIR/gui/target/release/lwcompat-gui"
DESKTOP_EXEC="$APP_DIR/start.sh"

say() { printf '[LWCompat installer] %s\n' "$*"; }
warn() { printf '[LWCompat installer] WARNING: %s\n' "$*" >&2; }
fail() { printf '[LWCompat installer] ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
LWCompat installer

Usage:
  ./install.sh
  ./install.sh --check
  ./install.sh --help

Options:
  --check   Check dependencies and installation environment only.
  --help    Show this help.
EOF
}

CHECK_ONLY=0

case "${1:-}" in
    "")
        ;;
    --check)
        CHECK_ONLY=1
        shift
        ;;
    --help|-h)
        usage
        exit 0
        ;;
    *)
        usage >&2
        fail "Unknown option: $1"
        ;;
esac

(( $# == 0 )) || fail "Unexpected argument: $1"

MISSING_CORE=()
MISSING_FAST_CACHE=()
MISSING_ICON=()

collect_missing() {
    local array_name="$1"
    shift

    local cmd

    for cmd in "$@"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            eval "$array_name+=(\"\$cmd\")"
        fi
    done
}

print_missing() {
    local label="$1"
    shift

    if (( $# == 0 )); then
        say "$label: OK"
        return
    fi

    warn "$label: missing command(s): $*"
}

package_hint_core() {
    if command -v dnf >/dev/null 2>&1; then
        say "Fedora dependency hint:"
        say "  sudo dnf install python3 util-linux procps-ng findutils coreutils"
    elif command -v apt-get >/dev/null 2>&1; then
        say "Debian/Ubuntu dependency hint:"
        say "  sudo apt install python3 util-linux procps findutils coreutils"
    elif command -v pacman >/dev/null 2>&1; then
        say "Arch dependency hint:"
        say "  sudo pacman -S python util-linux procps-ng findutils coreutils"
    fi
}

package_hint_fast_cache() {
    if command -v dnf >/dev/null 2>&1; then
        say "Fast Cache dependency hint:"
        say "  sudo dnf install sudo e2fsprogs rsync util-linux systemd"
    elif command -v apt-get >/dev/null 2>&1; then
        say "Fast Cache dependency hint:"
        say "  sudo apt install sudo e2fsprogs rsync util-linux systemd"
    elif command -v pacman >/dev/null 2>&1; then
        say "Fast Cache dependency hint:"
        say "  sudo pacman -S sudo e2fsprogs rsync util-linux systemd"
    fi
}

run_preflight() {
    collect_missing MISSING_CORE \
        bash python3 flock pgrep pkill find install mktemp

    collect_missing MISSING_FAST_CACHE \
        sudo mkfs.ext4 chattr lsattr rsync \
        mount umount mountpoint findmnt systemctl \
        truncate du df

    collect_missing MISSING_ICON \
        wrestool icotool identify

    echo
    say "Running dependency preflight..."

    print_missing "Core runtime" "${MISSING_CORE[@]}"

    if (( ${#MISSING_CORE[@]} > 0 )); then
        package_hint_core
        fail "Required core dependencies are missing."
    fi

    print_missing "Fast Asset Cache" "${MISSING_FAST_CACHE[@]}"

    if (( ${#MISSING_FAST_CACHE[@]} > 0 )); then
        package_hint_fast_cache
    fi

    if command -v pkexec >/dev/null 2>&1; then
        say "Graphical authentication: OK (pkexec)"
    else
        warn "Graphical authentication: pkexec not found."
        warn "Fast Cache can still be controlled from a terminal with sudo."
    fi

    if command -v cargo >/dev/null 2>&1; then
        say "Rust GUI build       : OK (cargo)"
    elif [[ -x "$GUI_SOURCE" ]]; then
        say "Rust GUI build       : using existing prebuilt binary"
    else
        warn "Rust GUI build       : cargo not found"
        warn "GUI will fall back to the script launcher unless a prebuilt binary is provided."
    fi

    if (( ${#MISSING_ICON[@]} == 0 )); then
        say "Icon extraction      : OK"
    else
        say "Icon extraction      : optional tools missing (${MISSING_ICON[*]})"
        say "                       system game icon will be used if needed"
    fi

    echo
}

run_preflight

find_game_dir() {
    if [[ -n "${LWCOMPAT_GAME_DIR:-}" && -f "$LWCOMPAT_GAME_DIR/LastWarLauncher.exe" ]]; then
        printf '%s\n' "$LWCOMPAT_GAME_DIR"
        return 0
    fi

    local default="$HOME/Games/LastWar/drive_c/users/steamuser/AppData/Local/FunFly/Last War-Survival Game"
    if [[ -f "$default/LastWarLauncher.exe" ]]; then
        printf '%s\n' "$default"
        return 0
    fi

    local found
    found="$(find "$HOME/Games" -type f -name LastWarLauncher.exe -print -quit 2>/dev/null || true)"
    [[ -n "$found" ]] || return 1
    dirname "$found"
}

find_umu() {
    if [[ -n "${LWCOMPAT_UMU:-}" && -f "$LWCOMPAT_UMU" ]]; then
        printf '%s\n' "$LWCOMPAT_UMU"
        return 0
    fi

    local candidates=(
        "$HOME/.local/share/faugus-launcher/umu-run"
        "$HOME/.local/bin/umu-run"
    )

    local candidate
    for candidate in "${candidates[@]}"; do
        if [[ -f "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    if command -v umu-run >/dev/null 2>&1; then
        command -v umu-run
        return 0
    fi

    return 1
}

find_proton() {
    if [[ -n "${LWCOMPAT_PROTON:-}" && -d "$LWCOMPAT_PROTON" ]]; then
        printf '%s\n' "$LWCOMPAT_PROTON"
        return 0
    fi

    local exact=(
        "$HOME/.local/share/Steam/compatibilitytools.d/Proton-GE Latest"
        "$HOME/.steam/root/compatibilitytools.d/Proton-GE Latest"
        "$HOME/.var/app/com.valvesoftware.Steam/data/Steam/compatibilitytools.d/Proton-GE Latest"
    )

    local candidate
    for candidate in "${exact[@]}"; do
        if [[ -d "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    local found
    found="$(find \
        "$HOME/.local/share/Steam/compatibilitytools.d" \
        "$HOME/.steam/root/compatibilitytools.d" \
        "$HOME/.var/app/com.valvesoftware.Steam/data/Steam/compatibilitytools.d" \
        -maxdepth 1 -mindepth 1 -type d -name 'Proton-GE*' -print 2>/dev/null \
        | sort -V | tail -n 1 || true)"

    [[ -n "$found" ]] || return 1
    printf '%s\n' "$found"
}

UMU="$(find_umu)" || fail "Faugus/UMU launcher was not found. Set LWCOMPAT_UMU=/path/to/umu-run and retry."
PROTON="$(find_proton)" || fail "GE-Proton was not found. Set LWCOMPAT_PROTON='/path/to/Proton-GE' and retry."

BOOTSTRAP_PREFIX="${LWCOMPAT_PREFIX:-$HOME/Games/LastWar}"
BOOTSTRAP_GAME_DIR="$BOOTSTRAP_PREFIX/drive_c/users/steamuser/AppData/Local/FunFly/Last War-Survival Game"

GAME_DIR=""

if [[ "${LWCOMPAT_BOOTSTRAP_FORCE:-0}" != "1" ]]; then
    GAME_DIR="$(find_game_dir || true)"
fi

if [[ -z "$GAME_DIR" ]]; then
    if (( CHECK_ONLY == 1 )); then
        echo
        say "Game installation : NOT FOUND"
        say "Fresh bootstrap   : AVAILABLE"
        say "Bootstrap prefix  : $BOOTSTRAP_PREFIX"
        say "UMU               : $UMU"
        say "Proton            : $PROTON"
        echo
        say "Preflight check completed successfully."
        say "No files were installed or modified."
        exit 0
    fi

    echo
    say "No usable Last War installation was selected."
    say "Starting LWCompat fresh bootstrap..."
    say "Bootstrap prefix: $BOOTSTRAP_PREFIX"
    echo

    LWCOMPAT_PREFIX="$BOOTSTRAP_PREFIX" \
    LWCOMPAT_UMU="$UMU" \
    LWCOMPAT_PROTON="$PROTON" \
        "$ROOT_DIR/src/bootstrap.sh"

    if [[ -f "$BOOTSTRAP_GAME_DIR/LastWarLauncher.exe" &&
          -f "$BOOTSTRAP_GAME_DIR/manifest.json" &&
          -f "$BOOTSTRAP_GAME_DIR/Game/LastWar.exe" ]]; then
        GAME_DIR="$BOOTSTRAP_GAME_DIR"
    else
        GAME_DIR="$(find_game_dir || true)"
    fi

    [[ -n "$GAME_DIR" ]] ||
        fail "Fresh bootstrap finished, but the Last War installation could not be found."
fi

PREFIX="${GAME_DIR%%/drive_c/*}"

MANIFEST="$GAME_DIR/manifest.json"
[[ -f "$MANIFEST" ]] || fail "manifest.json was not found in: $GAME_DIR"

say "Game directory : $GAME_DIR"
say "Wine prefix    : $PREFIX"
say "UMU            : $UMU"
say "Proton         : $PROTON"

if (( CHECK_ONLY == 1 )); then
    echo
    say "Preflight check completed successfully."
    say "No files were installed or modified."
    exit 0
fi

mkdir -p "$APP_DIR" "$APP_DIR/logs" "$BACKUP_DIR" "$BIN_DIR" "$APPS_DIR" "$ICONS_DIR"

install -m 0755 "$ROOT_DIR/src/lwcompat.sh" "$APP_DIR/lwcompat.sh"
install -m 0755 "$ROOT_DIR/src/start.sh" "$APP_DIR/start.sh"
install -m 0755 "$ROOT_DIR/src/bundle_proxy.py" "$APP_DIR/bundle_proxy.py"
install -m 0755 "$ROOT_DIR/src/connect_proxy.py" "$APP_DIR/connect_proxy.py"
install -m 0755 "$ROOT_DIR/src/bootstrap_client.py" "$APP_DIR/bootstrap_client.py"
install -m 0755 "$ROOT_DIR/src/bootstrap.sh" "$APP_DIR/bootstrap.sh"
install -m 0755 "$ROOT_DIR/src/update.sh" "$APP_DIR/update.sh"
install -m 0755 "$ROOT_DIR/src/fast_asset_cache_ctl.sh" "$APP_DIR/fast_asset_cache_ctl.sh"
install -m 0755 "$ROOT_DIR/src/overlay_ctl.sh" "$APP_DIR/overlay_ctl.sh"

if [[ -f "$ROOT_DIR/src/setup_fast_asset_cache.sh" ]]; then
    install -m 0755 \
        "$ROOT_DIR/src/setup_fast_asset_cache.sh" \
        "$APP_DIR/setup_fast_asset_cache.sh"

    install -m 0755 \
        "$ROOT_DIR/src/fast_asset_cache.sh" \
        "$APP_DIR/fast_asset_cache.sh"

    install -m 0644 \
        "$ROOT_DIR/systemd/lwcompat-fast-asset-cache.service" \
        "$APP_DIR/lwcompat-fast-asset-cache.service"
fi

if [[ ! -f "$BACKUP_DIR/manifest.json.initial" ]]; then
    cp -p "$MANIFEST" "$BACKUP_DIR/manifest.json.initial"
    say "Saved initial manifest backup."
fi

{
    printf 'LWCOMPAT_GAME_DIR=%q\n' "$GAME_DIR"
    printf 'LWCOMPAT_PREFIX=%q\n' "$PREFIX"
    printf 'LWCOMPAT_UMU=%q\n' "$UMU"
    printf 'LWCOMPAT_PROTON=%q\n' "$PROTON"
} > "$APP_DIR/config.sh"
chmod 0600 "$APP_DIR/config.sh"

ln -sfn "$APP_DIR/start.sh" "$BIN_DIR/lwcompat"
ln -sfn "$APP_DIR/fast_asset_cache_ctl.sh" "$BIN_DIR/lwcompat-fast-cache"
ln -sfn "$APP_DIR/overlay_ctl.sh" "$BIN_DIR/lwcompat-overlay"
ln -sfn "$APP_DIR/update.sh" "$BIN_DIR/lwcompat-update"

install_gui() {
    local mode
    local choice

    mode="${LWCOMPAT_GUI:-ask}"

    case "$mode" in
        1|yes|true|on|enable|enabled)
            choice="y"
            ;;
        0|no|false|off|disable|disabled)
            choice="n"
            ;;
        ask)
            if [[ -t 0 && -t 1 ]]; then
                echo
                say "LWCompat includes an optional native Rust GUI."
                say "The GUI uses the existing Bash/Python compatibility engine."
                echo
                read -r -p "Build and install the LWCompat GUI? [Y/n] " choice
                choice="${choice:-y}"
            else
                choice="n"
            fi
            ;;
        *)
            fail "Invalid LWCOMPAT_GUI value: $mode"
            ;;
    esac

    case "$choice" in
        y|Y|yes|YES|Yes)
            if [[ ! -f "$ROOT_DIR/gui/Cargo.toml" ]]; then
                say "GUI source was not found; using launcher fallback."
                return 0
            fi

            if command -v cargo >/dev/null 2>&1; then
                echo
                say "Building LWCompat GUI..."

                if ! cargo build \
                    --release \
                    --manifest-path "$ROOT_DIR/gui/Cargo.toml"
                then
                    say "GUI build failed; continuing with launcher fallback."
                    return 0
                fi
            elif [[ ! -x "$GUI_SOURCE" ]]; then
                say "Cargo was not found and no prebuilt GUI binary is available."
                say "Continuing with launcher fallback."
                return 0
            fi

            if [[ ! -x "$GUI_SOURCE" ]]; then
                say "GUI binary was not produced; using launcher fallback."
                return 0
            fi

            install -m 0755 "$GUI_SOURCE" "$GUI_INSTALL"
            ln -sfn "$GUI_INSTALL" "$BIN_DIR/lwcompat-gui"

            DESKTOP_EXEC="$GUI_INSTALL"

            say "LWCompat GUI installed."
            ;;
        *)
            rm -f "$BIN_DIR/lwcompat-gui"
            rm -f "$GUI_INSTALL"

            DESKTOP_EXEC="$APP_DIR/start.sh"

            say "GUI skipped; desktop entry will launch the compatibility engine directly."
            ;;
    esac
}

install_gui

ICON_VALUE="applications-games"
CUSTOM_ICON="$ICONS_DIR/lastwar-lwcompat.png"

extract_icon_from_exe() {
    local exe="$1"
    local tmp
    tmp="$(mktemp -d)"

    if ! command -v wrestool >/dev/null 2>&1 || ! command -v icotool >/dev/null 2>&1; then
        rm -rf "$tmp"
        return 1
    fi

    if ! wrestool -x -t14 "$exe" > "$tmp/icon.ico" 2>/dev/null; then
        rm -rf "$tmp"
        return 1
    fi

    if [[ ! -s "$tmp/icon.ico" ]]; then
        rm -rf "$tmp"
        return 1
    fi

    mkdir -p "$tmp/png"
    if ! icotool -x "$tmp/icon.ico" -o "$tmp/png" >/dev/null 2>&1; then
        rm -rf "$tmp"
        return 1
    fi

    local best=""
    if command -v identify >/dev/null 2>&1; then
        best="$(identify -format '%w %h %f\n' "$tmp"/png/*.png 2>/dev/null | sort -nr | head -n 1 | awk '{print $3}' || true)"
    fi

    if [[ -z "$best" ]]; then
        best="$(find "$tmp/png" -maxdepth 1 -type f -name '*.png' -printf '%s %f\n' 2>/dev/null | sort -nr | head -n 1 | awk '{print $2}' || true)"
    fi

    if [[ -n "$best" && -f "$tmp/png/$best" ]]; then
        cp -f "$tmp/png/$best" "$CUSTOM_ICON"
        rm -rf "$tmp"
        return 0
    fi

    rm -rf "$tmp"
    return 1
}

if [[ -f "$CUSTOM_ICON" ]]; then
    ICON_VALUE="$CUSTOM_ICON"
elif extract_icon_from_exe "$GAME_DIR/LastWarLauncher.exe"; then
    ICON_VALUE="$CUSTOM_ICON"
elif [[ -f "$GAME_DIR/Game/LastWar.exe" ]] && extract_icon_from_exe "$GAME_DIR/Game/LastWar.exe"; then
    ICON_VALUE="$CUSTOM_ICON"
else
    say "Could not extract the official game icon; using the system game icon."
    say "Optional packages: icoutils and ImageMagick."
fi

cat > "$APPS_DIR/lwcompat.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Last War (LWCompat)
Comment=Launch Last War: Survival Game through LWCompat
Exec=$DESKTOP_EXEC
Icon=$ICON_VALUE
Terminal=false
Categories=Game;
StartupNotify=true
Keywords=Last War;LWCompat;Game;
EOF
chmod 0755 "$APPS_DIR/lwcompat.desktop"

if command -v kbuildsycoca6 >/dev/null 2>&1; then
    kbuildsycoca6 >/dev/null 2>&1 || true
elif command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "$APPS_DIR" >/dev/null 2>&1 || true
fi

setup_fast_asset_cache() {
    local asset_target
    local setup_script
    local choice
    local mode

    asset_target="$PREFIX/drive_c/FunFly/Last War-Survival Game/Cache/AssetBundles"
    setup_script="$ROOT_DIR/src/setup_fast_asset_cache.sh"

    [[ -d "$asset_target" ]] || {
        say "Fast Asset Cache: AssetBundles directory was not found; skipping."
        return 0
    }

    [[ -x "$setup_script" ]] || {
        say "Fast Asset Cache setup script is not available; skipping."
        return 0
    }

    mode="${LWCOMPAT_FAST_CACHE:-ask}"

    case "$mode" in
        1|yes|true|on|enable|enabled)
            choice="y"
            ;;
        0|no|false|off|disable|disabled)
            choice="n"
            ;;
        ask)
            if [[ -t 0 && -t 1 ]]; then
                echo
                say "Fast Asset Cache can significantly reduce Last War startup time."
                say "It uses an ext4 casefold image for the large AssetBundles directory."
                say "Initial setup requires sudo and a one-time asset migration."
                echo
                read -r -p "Enable Fast Asset Cache? [Y/n] " choice
                choice="${choice:-y}"
            else
                say "Fast Asset Cache: non-interactive install detected; skipping."
                say "Enable later with: $APP_DIR/setup_fast_asset_cache.sh"
                return 0
            fi
            ;;
        *)
            fail "Invalid LWCOMPAT_FAST_CACHE value: $mode"
            ;;
    esac

    case "$choice" in
        y|Y|yes|YES|Yes)
            echo
            say "Configuring Fast Asset Cache..."

            LWCOMPAT_PREFIX="$PREFIX" \
                "$setup_script"

            say "Fast Asset Cache configured."
            ;;
        *)
            say "Fast Asset Cache skipped."
            say "You can enable it later with:"
            say "  LWCOMPAT_PREFIX='$PREFIX' $APP_DIR/setup_fast_asset_cache.sh"
            ;;
    esac
}

setup_fast_asset_cache

say "Installation complete."
say "Launch from your application menu: Last War (LWCompat)"
say "Or run: $BIN_DIR/lwcompat"
say "Logs: $APP_DIR/logs/"

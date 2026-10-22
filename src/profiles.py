#!/usr/bin/env python3
"""Switch between saved Last War logins without re-entering e-mail codes.

The game keeps its login session in a handful of Unity PlayerPrefs values
(HKCU\\Software\\FunFly\\Last War-Survival Game in the prefix's user.reg).
A profile is a copy of exactly those values. Everything else - game files,
Fast Asset Cache, per-character settings, the device identity - is shared,
so switching looks like the game's own "remember me" login.

    lwcompat-profile list
    lwcompat-profile save NAME     store the current login as NAME
    lwcompat-profile use NAME      save the active profile, then load NAME
    lwcompat-profile rename OLD NEW
    lwcompat-profile delete NAME

Profiles hold session tokens (as sensitive as a password): they are stored
with mode 0600 and their values are never printed. The game, its launcher
and wineserver must be stopped, because Wine rewrites user.reg on exit.
"""

import argparse
import fcntl
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

APP_DIR = Path(os.environ.get("LWCOMPAT_APP_DIR", Path.home() / ".local/share/lwcompat"))
PROFILE_DIR = Path(os.environ.get("LWCOMPAT_PROFILE_DIR", APP_DIR / "profiles"))
BACKUP_DIR = APP_DIR / "backups" / "profiles"
SECTION = "[Software\\\\FunFly\\\\Last War-Survival Game]"
KEEP_BACKUPS = 5

# PlayerPrefs that make up the login (Unity appends "_h<hash>" to names).
LOGIN_KEYS = {
    "Login.access_token",
    "Login.access_token_time",
    "Login.login_key",
    "Login.refresh_token",
    "Login.refresh_token_time",
    "Setting.GAME_UID",
    "Setting.CUSTOM_UID",
    "Last_LOGIN_TIME",
    "SERVER_IP",
    "SERVER_PORT",
    "SERVER_ZONE",
    "SERVER_COUNTRY",
}

NAME_RE = re.compile(r'^"(.*?)(?:_h\d+)?"=')
PROFILE_NAME_RE = re.compile(r"^[A-Za-z0-9._-]{1,40}$")


def die(message):
    print(f"[LWCompat profile] ERROR: {message}", file=sys.stderr)
    sys.exit(1)


def log(message):
    print(f"[LWCompat profile] {message}")


def user_reg():
    if "LWCOMPAT_USER_REG" in os.environ:
        return Path(os.environ["LWCOMPAT_USER_REG"])

    config = APP_DIR / "config.sh"
    out = subprocess.run(
        ["bash", "-c", 'source "$1" && printf %s "$LWCOMPAT_PREFIX"', "_", str(config)],
        capture_output=True, text=True,
    ).stdout
    if not out:
        die(f"cannot read LWCOMPAT_PREFIX from {config}")
    return Path(out) / "user.reg"


def ensure_stopped():
    if os.environ.get("LWCOMPAT_PROFILE_SKIP_CHECKS") == "1":
        return

    for name in ("LastWar.exe", "LastWarLauncher", "wineserver"):
        if subprocess.run(["pgrep", "-x", name], capture_output=True).returncode == 0:
            die(f"{name} is running; close the game (and wait for Wine to exit) first")

    lock = APP_DIR / "lwcompat.lock"
    if lock.exists():
        with open(lock) as handle:
            try:
                fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                die("an LWCompat session is running")


def split_entries(lines):
    """Group registry lines into entries (a value plus its continuation lines)."""
    entries = []
    for line in lines:
        if entries and entries[-1][-1].rstrip("\n").endswith("\\"):
            entries[-1].append(line)
        else:
            entries.append([line])
    return entries


def entry_key(entry):
    match = NAME_RE.match(entry[0])
    return match.group(1) if match else None


def read_section(path):
    """Return (before, section_entries, after) of the game's PlayerPrefs key."""
    lines = path.read_text(encoding="utf-8", errors="surrogateescape").splitlines(keepends=True)
    start = next((i for i, line in enumerate(lines) if line.startswith(SECTION)), None)
    if start is None:
        die("the game's settings are not in user.reg yet (start the game once)")

    end = start + 1
    while end < len(lines) and not lines[end].startswith("["):
        end += 1

    return lines[:start + 1], split_entries(lines[start + 1:end]), lines[end:]


def current_login(path):
    _, entries, _ = read_section(path)
    return [entry for entry in entries if entry_key(entry) in LOGIN_KEYS]


def write_private(path, text):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    tmp = path.with_name(path.name + ".tmp")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8", errors="surrogateescape") as handle:
        handle.write(text)
    os.replace(tmp, path)


def profile_path(name):
    if not PROFILE_NAME_RE.match(name):
        die("profile names may use letters, digits, '.', '_' and '-' (max 40)")
    return PROFILE_DIR / f"{name}.reglines"


def active_name():
    marker = PROFILE_DIR / "active"
    return marker.read_text().strip() if marker.is_file() else None


def save(name, path):
    login = current_login(path)
    keys = {entry_key(e) for e in login}
    if not {"Login.refresh_token", "Login.access_token"} <= keys:
        die("no login found in user.reg (log in once in the game first)")

    write_private(profile_path(name), "".join(line for entry in login for line in entry))
    write_private(PROFILE_DIR / "active", name + "\n")
    log(f"saved current login as '{name}' ({len(login)} values)")


def backup(path):
    BACKUP_DIR.mkdir(parents=True, exist_ok=True, mode=0o700)
    target = BACKUP_DIR / f"user.reg.{time.strftime('%Y%m%d-%H%M%S')}"
    shutil.copy2(path, target)
    os.chmod(target, 0o600)
    for old in sorted(BACKUP_DIR.glob("user.reg.*"))[:-KEEP_BACKUPS]:
        old.unlink()


def use(name, path):
    source = profile_path(name)
    if not source.is_file():
        die(f"no profile '{name}'")

    active = active_name()
    if active and active != name and profile_path(active).is_file():
        # Tokens are refreshed while playing; keep the latest ones.
        save(active, path)

    before, entries, after = read_section(path)
    kept = [entry for entry in entries if entry_key(entry) not in LOGIN_KEYS]

    # Values end before the blank line that closes the section.
    while kept and kept[-1] == ["\n"]:
        kept.pop()

    loaded = source.read_text(encoding="utf-8", errors="surrogateescape")
    if not loaded.endswith("\n"):
        loaded += "\n"

    backup(path)
    text = "".join(before) + "".join(line for e in kept for line in e) + loaded + "\n" + "".join(after)

    tmp = path.with_name(path.name + ".lwcompat-tmp")
    tmp.write_text(text, encoding="utf-8", errors="surrogateescape")
    shutil.copymode(path, tmp)
    os.replace(tmp, path)

    write_private(PROFILE_DIR / "active", name + "\n")
    log(f"switched to '{name}'")


def main():
    parser = argparse.ArgumentParser(prog="lwcompat-profile", description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="cmd", required=True)
    sub.add_parser("list")
    for cmd in ("save", "use", "delete"):
        sub.add_parser(cmd).add_argument("name")
    rename = sub.add_parser("rename")
    rename.add_argument("old")
    rename.add_argument("new")
    args = parser.parse_args()

    if args.cmd == "list":
        active = active_name()
        names = sorted(p.stem for p in PROFILE_DIR.glob("*.reglines")) if PROFILE_DIR.is_dir() else []
        if not names:
            log("no profiles yet; log in with an account and run: lwcompat-profile save NAME")
        for name in names:
            print(("* " if name == active else "  ") + name)
        return

    if args.cmd == "rename":
        source, target = profile_path(args.old), profile_path(args.new)
        if not source.is_file():
            die(f"no profile '{args.old}'")
        if target.exists():
            die(f"a profile named '{args.new}' already exists")
        source.rename(target)
        if active_name() == args.old:
            write_private(PROFILE_DIR / "active", args.new + "\n")
        log(f"renamed '{args.old}' to '{args.new}'")
        return

    if args.cmd == "delete":
        target = profile_path(args.name)
        if not target.is_file():
            die(f"no profile '{args.name}'")
        target.unlink()
        if active_name() == args.name:
            (PROFILE_DIR / "active").unlink()
        log(f"deleted '{args.name}'")
        return

    ensure_stopped()
    path = user_reg()
    if not path.is_file():
        die(f"{path} not found")

    if args.cmd == "save":
        save(args.name, path)
    else:
        use(args.name, path)


if __name__ == "__main__":
    main()

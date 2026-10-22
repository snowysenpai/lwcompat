#!/usr/bin/env python3
"""Fetch the official signed Last War manifest natively on Linux.

Under Wine, the launcher's schannel TLS stack can stall on the final TLS
record of the remote manifest body. The launcher then reports
"error decoding response body ... operation timed out" forever, even though
the CDN delivered the whole file.

This helper reads the remote version the launcher already resolved from
Launcher.log, downloads <base>/manifest/<channel>/manifests/<version>.json
and its .sig with normal TLS verification, validates them and installs them
as manifest.json / manifest.json.sig. The launcher still verifies the
signature itself; this only replaces the download step.

Exit codes:
    0  newer signed manifest installed
    3  nothing to do (local manifest already current or newer)
    1  error (nothing changed)
"""

import argparse
import base64
import hashlib
import json
import os
import re
import shutil
import sys
import time
from pathlib import Path
from urllib.request import Request, urlopen

DEFAULT_BASE = "https://lastwar-cdn.akamaized.net/hotupdate/pc/micro"
REMOTE_RE = re.compile(
    r"Remote manifest version:\s*([^,\s]+),(\d+),([0-9a-fA-F]*),(\d+)"
)
SIG_SIZE = 64


def log(message):
    print(f"[LWCompat manifest] {message}", flush=True)


def remote_from_log(path):
    text = Path(path).read_text(encoding="utf-8", errors="replace")
    matches = REMOTE_RE.findall(text)

    if not matches:
        return None

    channel, version, _digest, size = matches[-1]
    return channel, int(version), int(size)


def local_version(manifest):
    try:
        return int(json.loads(manifest.read_text(encoding="utf-8"))["version"])
    except Exception:
        return -1


def fetch(url, retries=3):
    last = None

    for attempt in range(1, retries + 1):
        try:
            request = Request(
                url,
                headers={
                    "User-Agent": "LWCompat",
                    "Accept-Encoding": "identity",
                },
            )

            with urlopen(request, timeout=30) as response:
                body = response.read()
                headers = response.headers

            declared = headers.get("Content-Length")

            if declared is not None and int(declared) != len(body):
                raise ValueError(
                    f"short body: {len(body)}/{declared} bytes"
                )

            content_md5 = headers.get("Content-MD5")

            if content_md5:
                actual = base64.b64encode(hashlib.md5(body).digest()).decode()

                if actual != content_md5.strip():
                    raise ValueError("Content-MD5 mismatch")

            return body
        except Exception as exc:
            last = exc
            log(f"download attempt {attempt}/{retries} failed: {exc}")
            time.sleep(1)

    raise RuntimeError(f"{url}: {last}")


def write_atomic(path, data):
    tmp = path.with_name(path.name + ".lwcompat-tmp")
    tmp.write_bytes(data)
    os.replace(tmp, path)


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--game-dir", required=True)
    parser.add_argument("--launcher-log", required=True)
    parser.add_argument("--backup-dir", required=True)
    parser.add_argument("--base", default=DEFAULT_BASE)
    args = parser.parse_args()

    game_dir = Path(args.game_dir)
    manifest = game_dir / "manifest.json"
    signature = game_dir / "manifest.json.sig"

    remote = remote_from_log(args.launcher_log)

    if remote is None:
        log("no remote manifest version in launcher log")
        return 1

    channel, version, size = remote
    current = local_version(manifest)

    log(f"local={current} remote={channel},{version} size={size}")

    if current >= version:
        log("local manifest already current")
        return 3

    url = f"{args.base.rstrip('/')}/manifest/{channel}/manifests/{version}.json"

    try:
        body = fetch(url)
        sig = fetch(url + ".sig")

        if len(body) != size:
            raise ValueError(f"size {len(body)} != announced {size}")

        if len(sig) != SIG_SIZE:
            raise ValueError(f"signature is {len(sig)} bytes, expected {SIG_SIZE}")

        data = json.loads(body.decode("utf-8"))

        if int(data.get("version", -1)) != version:
            raise ValueError(f"manifest version {data.get('version')} != {version}")

        if str(data.get("channel", channel)) != channel:
            raise ValueError(f"manifest channel {data.get('channel')} != {channel}")

        if not data.get("files"):
            raise ValueError("manifest has no files")
    except Exception as exc:
        log(f"ERROR: {exc}")
        return 1

    backup = Path(args.backup_dir) / time.strftime(f"manifest-{current}-%Y%m%d-%H%M%S")
    backup.mkdir(parents=True, exist_ok=True)

    for item in (manifest, signature):
        if item.is_file():
            shutil.copy2(item, backup / item.name)

    write_atomic(signature, sig)
    write_atomic(manifest, body)

    log(f"installed signed manifest {version} (backup: {backup})")
    return 0


if __name__ == "__main__":
    sys.exit(main())

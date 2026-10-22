#!/usr/bin/env python3
"""Fetch the official signed Last War manifest natively on Linux.

Under Wine, the launcher's schannel TLS stack can stall on the final TLS
record of the remote manifest body. The launcher then reports
"error decoding response body ... operation timed out" forever, even though
the CDN delivered the whole file.

This helper reads the remote version the launcher already resolved from
Launcher.log, downloads <base>/manifest/<channel>/manifests/<version>.json
and its .sig with normal TLS verification, validates them and installs them
as manifest.json / manifest.json.sig.

Before installing, the Ed25519 signature is checked with the launcher's own
public key. The key is not shipped with LWCompat: it is located inside the
installed LastWarLauncher.exe by finding the 32 bytes that verify the
manifest/signature pair the launcher already accepted, and cached per
launcher build. If the key cannot be determined (or libcrypto is missing)
the check is skipped with a warning and the launcher remains the verifier.

Exit codes:
    0  newer signed manifest installed
    3  nothing to do (local manifest already current or newer)
    1  error (nothing changed)
"""

import argparse
import base64
import ctypes
import ctypes.util
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
# String the launcher keeps next to its manifest public key.
KEY_ANCHOR = b"configured manifest public key"
KEY_SEARCH_RADIUS = 512 * 1024
EVP_PKEY_ED25519 = 1087


def log(message):
    print(f"{time.strftime('%H:%M:%S')} [LWCompat manifest] {message}", flush=True)


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


def load_libcrypto():
    name = ctypes.util.find_library("crypto") or "libcrypto.so.3"
    try:
        lib = ctypes.CDLL(name)
    except OSError:
        return None

    lib.EVP_PKEY_new_raw_public_key.restype = ctypes.c_void_p
    lib.EVP_PKEY_new_raw_public_key.argtypes = [
        ctypes.c_int, ctypes.c_void_p, ctypes.c_char_p, ctypes.c_size_t]
    lib.EVP_MD_CTX_new.restype = ctypes.c_void_p
    lib.EVP_MD_CTX_free.argtypes = [ctypes.c_void_p]
    lib.EVP_PKEY_free.argtypes = [ctypes.c_void_p]
    lib.EVP_DigestVerifyInit.argtypes = [ctypes.c_void_p] * 5
    lib.EVP_DigestVerify.argtypes = [
        ctypes.c_void_p, ctypes.c_char_p, ctypes.c_size_t, ctypes.c_char_p, ctypes.c_size_t]
    return lib


def ed25519_verify(lib, key, message, signature):
    pkey = lib.EVP_PKEY_new_raw_public_key(EVP_PKEY_ED25519, None, key, len(key))
    if not pkey:
        return False

    ctx = lib.EVP_MD_CTX_new()
    try:
        return (lib.EVP_DigestVerifyInit(ctx, None, None, None, pkey) == 1 and
                lib.EVP_DigestVerify(ctx, signature, len(signature), message, len(message)) == 1)
    finally:
        lib.EVP_MD_CTX_free(ctx)
        lib.EVP_PKEY_free(pkey)


def find_launcher_key(lib, launcher, message, signature, cache_dir):
    """Locate the launcher's manifest key using a pair it already accepted."""
    data = launcher.read_bytes()
    cache = cache_dir / f"manifest-key-{hashlib.sha256(data).hexdigest()[:16]}.hex"

    if cache.is_file():
        key = bytes.fromhex(cache.read_text().strip())
        if ed25519_verify(lib, key, message, signature):
            return key

    anchor = data.find(KEY_ANCHOR)
    if anchor < 0:
        return None

    # The key sits right next to the anchor in known builds; search outward.
    for distance in range(KEY_SEARCH_RADIUS):
        for offset in (anchor - distance, anchor + distance):
            if offset < 0 or offset + 32 > len(data):
                continue
            key = data[offset:offset + 32]
            if key.count(key[0]) > 24:
                continue
            if ed25519_verify(lib, key, message, signature):
                cache_dir.mkdir(parents=True, exist_ok=True)
                cache.write_text(key.hex() + "\n")
                return key

    return None


def check_signature(launcher, manifest, signature, body, sig):
    """True/False when the signature could be checked, None when skipped."""
    lib = load_libcrypto()
    if lib is None:
        log("WARNING: libcrypto not available; leaving signature check to the launcher")
        return None

    if not (launcher.is_file() and manifest.is_file() and signature.is_file()):
        log("WARNING: no accepted local manifest to locate the key; skipping signature check")
        return None

    cache_dir = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache")) / "lwcompat"
    key = find_launcher_key(lib, launcher, manifest.read_bytes(), signature.read_bytes(), cache_dir)
    if key is None:
        log("WARNING: launcher manifest key not found; skipping signature check")
        return None

    return ed25519_verify(lib, key, body, sig)


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
    parser.add_argument("--launcher", help="defaults to <game-dir>/LastWarLauncher.exe")
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

    launcher = Path(args.launcher) if args.launcher else game_dir / "LastWarLauncher.exe"
    verified = check_signature(launcher, manifest, signature, body, sig)

    if verified is False:
        log("ERROR: manifest signature does not verify with the launcher's key; not installing")
        return 1
    if verified:
        log("signature verified with the launcher's key")

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

#!/usr/bin/env python3

import argparse
import json
import os
import shutil
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path, PureWindowsPath
from urllib.error import HTTPError, URLError
from urllib.parse import quote
from urllib.request import Request, urlopen

USER_AGENT = "LWCompat/0.1"
DEFAULT_WORKERS = 6
MAX_RETRIES = 6
CHUNK_SIZE = 1024 * 1024

print_lock = threading.Lock()


def log(message):
    with print_lock:
        print(message, flush=True)


def human_size(value):
    units = ["B", "KiB", "MiB", "GiB"]
    size = float(value)

    for unit in units:
        if size < 1024 or unit == units[-1]:
            return f"{size:.1f} {unit}"
        size /= 1024

    return f"{value} B"


def target_path(game_dir, manifest_path):
    win = PureWindowsPath(manifest_path)
    return game_dir.joinpath("Game", *win.parts)


def download_url(base_url, manifest_path, file_hash):
    # Last War's micro CDN stores files by basename + manifest hash.
    filename = PureWindowsPath(manifest_path).name
    encoded = quote(filename, safe="")

    return (
        base_url.rstrip("/")
        + "/files/"
        + encoded
        + "."
        + file_hash
        + ".bin"
    )


def download_one(game_dir, base_url, entry, index, total):
    rel = entry["path"]
    expected_size = int(entry["size"])
    file_hash = entry["hash"]

    target = target_path(game_dir, rel)
    part = target.with_name(target.name + ".lwcompat.part")
    url = download_url(base_url, rel, file_hash)

    target.parent.mkdir(parents=True, exist_ok=True)

    if target.is_file() and target.stat().st_size == expected_size:
        return ("skip", rel, expected_size)

    if part.exists() and part.stat().st_size > expected_size:
        part.unlink()

    for attempt in range(1, MAX_RETRIES + 1):
        existing = part.stat().st_size if part.exists() else 0

        if existing == expected_size:
            os.replace(part, target)
            return ("done", rel, expected_size)

        headers = {
            "User-Agent": USER_AGENT,
            "Accept": "*/*",
            "Accept-Encoding": "identity",
            "Connection": "close",
        }

        if existing:
            headers["Range"] = f"bytes={existing}-"

        request = Request(url, headers=headers)

        try:
            with urlopen(request, timeout=60) as response:
                status = getattr(response, "status", 200)

                if existing and status == 206:
                    mode = "ab"
                else:
                    # CDN ignored Range or this is a fresh download.
                    existing = 0
                    mode = "wb"

                log(
                    f"[{index}/{total}] {rel} "
                    f"({human_size(expected_size)}) "
                    f"attempt={attempt}"
                    + (
                        f" resume={human_size(existing)}"
                        if existing
                        else ""
                    )
                )

                with part.open(mode) as output:
                    while True:
                        chunk = response.read(CHUNK_SIZE)

                        if not chunk:
                            break

                        output.write(chunk)

                    output.flush()
                    os.fsync(output.fileno())

            actual = part.stat().st_size

            if actual != expected_size:
                raise RuntimeError(
                    f"size mismatch: expected {expected_size}, got {actual}"
                )

            os.replace(part, target)
            return ("done", rel, expected_size)

        except HTTPError as exc:
            # A fully completed .part may get 416 when resuming.
            if (
                exc.code == 416
                and part.exists()
                and part.stat().st_size == expected_size
            ):
                os.replace(part, target)
                return ("done", rel, expected_size)

            error = f"HTTP {exc.code}"

        except (URLError, TimeoutError, OSError, RuntimeError) as exc:
            error = str(exc)

        if attempt == MAX_RETRIES:
            raise RuntimeError(
                f"{rel}: failed after {MAX_RETRIES} attempts: {error}"
            )

        delay = min(attempt * 2, 10)
        log(
            f"[retry] {rel}: {error}; "
            f"retrying in {delay}s"
        )
        time.sleep(delay)

    raise RuntimeError(f"{rel}: unexpected download failure")


def install_manifest(source, destination):
    temp = destination.with_name(
        destination.name + ".lwcompat.tmp"
    )

    with source.open("rb") as src, temp.open("wb") as dst:
        shutil.copyfileobj(src, dst)
        dst.flush()
        os.fsync(dst.fileno())

    os.replace(temp, destination)


def main():
    parser = argparse.ArgumentParser(
        description="Download Last War micro-client files natively on Linux."
    )

    parser.add_argument(
        "game_dir",
        type=Path,
        help="Last War-Survival Game directory inside the Wine prefix",
    )

    parser.add_argument(
        "--manifest",
        type=Path,
        help="Manifest source; defaults to GAME_DIR/Temp/manifest.temp",
    )

    parser.add_argument(
        "--workers",
        type=int,
        default=DEFAULT_WORKERS,
    )

    parser.add_argument(
        "--plan",
        action="store_true",
        help="Show missing files without downloading",
    )

    args = parser.parse_args()

    game_dir = args.game_dir.expanduser().resolve()

    manifest_path = (
        args.manifest.expanduser().resolve()
        if args.manifest
        else game_dir / "Temp" / "manifest.temp"
    )

    if not manifest_path.is_file():
        raise SystemExit(
            f"Manifest not found: {manifest_path}"
        )

    try:
        manifest = json.loads(
            manifest_path.read_text(encoding="utf-8")
        )
    except Exception as exc:
        raise SystemExit(
            f"Failed to read manifest: {exc}"
        )

    files = manifest.get("files")
    base_url = manifest.get("url")

    if not isinstance(files, list) or not files:
        raise SystemExit("Manifest contains no files list.")

    if not isinstance(base_url, str) or not base_url.startswith("https://"):
        raise SystemExit(
            f"Invalid manifest URL: {base_url!r}"
        )

    missing = []
    existing_bytes = 0
    missing_bytes = 0
    total_bytes = 0

    for entry in files:
        try:
            rel = entry["path"]
            expected = int(entry["size"])
            file_hash = entry["hash"]
        except (KeyError, TypeError, ValueError):
            raise SystemExit(
                f"Invalid manifest file entry: {entry!r}"
            )

        if not rel or not file_hash or expected < 0:
            raise SystemExit(
                f"Invalid manifest file entry: {entry!r}"
            )

        total_bytes += expected

        target = target_path(game_dir, rel)

        if target.is_file() and target.stat().st_size == expected:
            existing_bytes += expected
        else:
            missing.append(entry)
            missing_bytes += expected

    print()
    print("LWCompat native client bootstrap")
    print(f"Manifest : {manifest_path}")
    print(f"Version  : {manifest.get('version')}")
    print(f"CDN      : {base_url}")
    print(f"Files    : {len(files)}")
    print(f"Existing : {len(files) - len(missing)}")
    print(f"Missing  : {len(missing)}")
    print(
        f"Total    : {human_size(total_bytes)} "
        f"(missing {human_size(missing_bytes)})"
    )
    print()

    if args.plan:
        for entry in missing:
            print(
                f"MISSING "
                f"{entry['path']} "
                f"({human_size(int(entry['size']))})"
            )

        return 0

    if not missing:
        print("All client files are already present.")
    else:
        workers = max(1, min(args.workers, 16))

        print(
            f"Downloading with {workers} native Linux workers..."
        )
        print()

        completed_bytes = 0
        skipped_bytes = 0

        with ThreadPoolExecutor(max_workers=workers) as executor:
            futures = {
                executor.submit(
                    download_one,
                    game_dir,
                    base_url,
                    entry,
                    index,
                    len(missing),
                ): entry
                for index, entry in enumerate(missing, 1)
            }

            try:
                for future in as_completed(futures):
                    status, rel, size = future.result()

                    if status == "skip":
                        skipped_bytes += size
                    else:
                        completed_bytes += size

                    log(
                        f"[OK] {rel} "
                        f"downloaded={human_size(completed_bytes)}"
                    )

            except Exception as exc:
                for future in futures:
                    future.cancel()

                raise SystemExit(
                    f"\n[LWCompat] Download failed: {exc}"
                )

    # Final verification across the complete file list.
    bad = []

    for entry in files:
        target = target_path(game_dir, entry["path"])
        expected = int(entry["size"])

        if not target.is_file():
            bad.append(
                f"{entry['path']}: missing"
            )
        elif target.stat().st_size != expected:
            bad.append(
                f"{entry['path']}: "
                f"expected {expected}, "
                f"got {target.stat().st_size}"
            )

    if bad:
        print()
        print("Final verification FAILED:", file=sys.stderr)

        for problem in bad[:20]:
            print(
                f"  {problem}",
                file=sys.stderr,
            )

        if len(bad) > 20:
            print(
                f"  ... and {len(bad) - 20} more",
                file=sys.stderr,
            )

        return 1

    destination_manifest = game_dir / "manifest.json"
    install_manifest(manifest_path, destination_manifest)

    print()
    print("Client verification: OK")
    print(f"Installed manifest: {destination_manifest}")
    print("Native bootstrap complete.")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())

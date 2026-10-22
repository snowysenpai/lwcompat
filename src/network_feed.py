#!/usr/bin/env python3

import argparse
import ipaddress
import math
import os
import re
import signal
import subprocess
import time
from pathlib import Path


CACHE_ROOT = Path(
    os.environ.get(
        "XDG_CACHE_HOME",
        str(Path.home() / ".cache"),
    )
)
STATE_FILE = CACHE_ROOT / "lwcompat" / "network.txt"

RTT_RE = re.compile(r"\brtt:([\d.]+)/([\d.]+)")
RETRANS_RE = re.compile(r"\bretrans:(\d+)(?:/(\d+))?")
BYTES_SENT_RE = re.compile(r"\bbytes_sent:(\d+)")
BYTES_RECV_RE = re.compile(r"\bbytes_received:(\d+)")
LASTSND_RE = re.compile(r"\blastsnd:(\d+)")
LASTRCV_RE = re.compile(r"\blasrcv:(\d+)")

running = True


def stop_handler(_signum, _frame):
    global running
    running = False


def split_endpoint(value):
    value = value.strip()

    if value.startswith("["):
        pos = value.rfind("]:")
        if pos == -1:
            return value, 0
        host = value[1:pos]
        port_text = value[pos + 2:]
    else:
        try:
            host, port_text = value.rsplit(":", 1)
        except ValueError:
            return value, 0

    try:
        port = int(port_text)
    except ValueError:
        port = 0

    return host, port


def is_loopback(host):
    host = host.split("%", 1)[0]

    try:
        return ipaddress.ip_address(host).is_loopback
    except ValueError:
        return host in {"localhost", "127.0.0.1", "::1"}


def number(regex, text, default=0):
    match = regex.search(text)
    if not match:
        return default

    try:
        return int(match.group(1))
    except (TypeError, ValueError):
        return default


def parse_retrans(text):
    match = RETRANS_RE.search(text)
    if not match:
        return 0

    first = int(match.group(1))
    second = match.group(2)

    if second is not None:
        return int(second)

    return first


def read_sockets():
    try:
        result = subprocess.run(
            ["ss", "-H", "-t", "-i", "-n", "-p"],
            capture_output=True,
            text=True,
            timeout=3,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return []

    lines = result.stdout.splitlines()
    blocks = []
    current = []

    for raw in lines:
        line = raw.strip()

        if line.startswith("ESTAB "):
            if current:
                blocks.append(current)

            current = [line]

        elif current:
            current.append(line)

    if current:
        blocks.append(current)

    sockets = []

    for block in blocks:
        base = block[0]

        if "LastWar.exe" not in base:
            continue

        parts = base.split()

        if len(parts) < 5:
            continue

        local_text = parts[3]
        remote_text = parts[4]

        remote_host, remote_port = split_endpoint(remote_text)
        local_host, local_port = split_endpoint(local_text)

        if not remote_port:
            continue

        if is_loopback(remote_host):
            continue

        detail = " ".join(block[1:])

        rtt_match = RTT_RE.search(detail)
        if not rtt_match:
            continue

        rtt = float(rtt_match.group(1))
        rttvar = float(rtt_match.group(2))

        sockets.append(
            {
                "local_host": local_host,
                "local_port": local_port,
                "remote_host": remote_host,
                "remote_port": remote_port,
                "rtt": rtt,
                "rttvar": rttvar,
                "retrans": parse_retrans(detail),
                "bytes_sent": number(BYTES_SENT_RE, detail),
                "bytes_received": number(BYTES_RECV_RE, detail),
                "lastsnd": number(LASTSND_RE, detail, 999999),
                "lastrcv": number(LASTRCV_RE, detail, 999999),
            }
        )

    return sockets


def score_socket(sock, sticky_endpoint=None):
    score = 0.0
    port = sock["remote_port"]

    # Observed Last War realtime pattern:
    # server #1573 -> port 11573
    # server #1153 -> port 11153
    if 10000 <= port < 20000:
        score += 2500.0

    if port not in (80, 443):
        score += 1000.0

    traffic = sock["bytes_sent"] + sock["bytes_received"]

    if traffic > 0:
        score += min(math.log10(traffic + 1) * 100.0, 800.0)

    activity_age = min(sock["lastsnd"], sock["lastrcv"])

    if activity_age < 999999:
        score += max(0.0, 400.0 - activity_age * 0.2)

    endpoint = (sock["remote_host"], sock["remote_port"])

    if endpoint == sticky_endpoint:
        score += 300.0

    return score


class NetworkState:
    def __init__(self):
        self.endpoint = None
        self.previous_rtt = None
        self.jitter = 0.0

    def update(self):
        sockets = read_sockets()

        if not sockets:
            self.endpoint = None
            self.previous_rtt = None
            self.jitter = 0.0
            return None

        selected = max(
            sockets,
            key=lambda sock: score_socket(sock, self.endpoint),
        )

        endpoint = (
            selected["remote_host"],
            selected["remote_port"],
        )

        if endpoint != self.endpoint:
            self.endpoint = endpoint
            self.previous_rtt = None
            self.jitter = 0.0

        rtt = selected["rtt"]

        if self.previous_rtt is not None:
            delta = abs(rtt - self.previous_rtt)
            self.jitter += (delta - self.jitter) / 8.0

        self.previous_rtt = rtt

        return selected


def format_state(sock, state, verbose=False):
    if sock is None:
        return "NET --"

    port = sock["remote_port"]

    if 10000 <= port < 20000:
        server = f"#{port - 10000}"
    else:
        server = "NET"

    text = (
        f"{server} | "
        f"RTT {sock['rtt']:.1f} ms | "
        f"Jitter {state.jitter:.1f} ms | "
        f"Var {sock['rttvar']:.1f} ms | "
        f"Rtx {sock['retrans']}"
    )

    if verbose:
        text += f" | {sock['remote_host']}:{port}"

    return text


def write_state(text):
    STATE_FILE.parent.mkdir(parents=True, exist_ok=True)

    temp = STATE_FILE.with_name(
        f"{STATE_FILE.name}.{os.getpid()}.tmp"
    )
    temp.write_text(text + "\n", encoding="utf-8")
    os.replace(temp, STATE_FILE)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--interval", type=float, default=0.75)
    parser.add_argument("--once", action="store_true")
    parser.add_argument("--watch", action="store_true")
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args()

    state = NetworkState()

    if args.once:
        sock = state.update()
        text = format_state(sock, state, args.verbose)
        print(text)
        return

    signal.signal(signal.SIGTERM, stop_handler)
    signal.signal(signal.SIGINT, stop_handler)

    try:
        while running:
            sock = state.update()
            text = format_state(sock, state, args.verbose)

            write_state(text)

            if args.watch:
                print(text, flush=True)

            time.sleep(max(args.interval, 0.2))

    finally:
        write_state("NET --")


if __name__ == "__main__":
    main()

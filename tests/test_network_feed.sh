#!/usr/bin/env bash
# network_feed.py route verdict with a fake clock and fake sockets.
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

out="$(python3 -I - "$ROOT/src/network_feed.py" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("feed", sys.argv[1])
feed = importlib.util.module_from_spec(spec); spec.loader.exec_module(feed)

now = [100.0]
sockets = []
feed.read_sockets = lambda: list(sockets)
state = feed.NetworkState(clock=lambda: now[0])

def sock(local_port, rtt, remote_port=11573):
    return {"local_host": "10.0.0.2", "local_port": local_port, "remote_host": "166.117.204.28",
            "remote_port": remote_port, "rtt": rtt, "rttvar": 2.0, "retrans": 0,
            "bytes_sent": 5000, "bytes_received": 9000, "lastsnd": 10, "lastrcv": 10}

def step(seconds, *socks):
    sockets[:] = socks
    now[0] += seconds
    return feed.format_state(state.update(), state)

print("fresh", step(0, sock(40001, 33)))
print("fast", step(3.5, sock(40001, 33)))
print("fast_later", step(5, sock(40001, 170)))
print("reconnect", step(1, sock(40002, 160)))
print("slow", step(3.5, sock(40002, 160)))
print("gone", step(1))
PY
)"
line() { grep "^$1 " <<<"$out" | cut -d' ' -f2-; }

[[ "$(line fresh)" == *"Route ?"* ]] && pass "no verdict before the RTT settles" || fail "fresh: $(line fresh)"
[[ "$(line fast)" == "#1573 | RTT 33.0 ms"*"Route fast" ]] && pass "~30 ms connection is fast (HUD prefix unchanged)" || fail "fast: $(line fast)"
[[ "$(line fast_later)" == *"Route fast" ]] && pass "verdict is latched per connection" || fail "latched: $(line fast_later)"
[[ "$(line reconnect)" == *"Age 0 s | Route ?" ]] && pass "same server, new local port = new connection" || fail "reconnect: $(line reconnect)"
[[ "$(line slow)" == *"Route slow" ]] && pass "~160 ms connection is slow" || fail "slow: $(line slow)"
assert_eq "NET --" "$(line gone)" "no game socket"

finish

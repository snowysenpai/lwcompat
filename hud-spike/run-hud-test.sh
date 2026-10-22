#!/usr/bin/env bash
set -u

cd "$HOME/lwcompat"

pkill -f '[n]etwork_feed.py' \
    2>/dev/null || true

python3 src/network_feed.py \
    --interval 0.75 \
    >/tmp/lwcompat-network.log 2>&1 &

NET_PID=$!

cleanup() {
    kill "$NET_PID" \
        2>/dev/null || true
}

trap cleanup EXIT INT TERM

export VK_LAYER_PATH="$HOME/lwcompat/hud-spike/build"
export VK_INSTANCE_LAYERS="VK_LAYER_LWCOMPAT_hud_spike"

unset MANGOHUD
unset MANGOHUD_CONFIG
unset MANGOHUD_CONFIGFILE

~/.local/bin/lwcompat

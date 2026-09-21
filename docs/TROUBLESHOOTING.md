# Troubleshooting

## Show LWCompat log

```bash
tail -n 200 ~/.local/share/lwcompat/logs/lwcompat.log
```

## Show bridge log

```bash
tail -n 200 ~/.local/share/lwcompat/logs/proxy.log
```

## Confirm both local bridge listeners

```bash
ss -ltn '( sport = :18080 or sport = :18081 )'
```

## Verify current patched manifest endpoints

```bash
GAME_DIR="$(bash -c 'source ~/.local/share/lwcompat/config.sh; printf "%s" "$LWCOMPAT_GAME_DIR"')"

grep -Eo '"bundle_url"[^,}]+' "$GAME_DIR/manifest.json"
grep -Eo '"bundle_ver_url"[^,}]+' "$GAME_DIR/manifest.json"
```

Expected values while LWCompat is installed:

```text
http://127.0.0.1:18080/
http://127.0.0.1:18081
```

## Run the session supervisor in a terminal

```bash
~/.local/share/lwcompat/lwcompat.sh
```

This is useful when the desktop entry closes too quickly to show an error.

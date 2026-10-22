# Troubleshooting

Start with the diagnostics report; it is read-only and hides your home directory:

```bash
lwcompat-doctor
```

## Logs

```bash
tail -n 200 ~/.local/share/lwcompat/logs/lwcompat.log      # newest session
ls ~/.local/share/lwcompat/logs/sessions/                   # last 10 sessions
```

The official launcher's own log is `Launcher.log` in the game directory.

## Run the session supervisor in a terminal

```bash
~/.local/bin/lwcompat
```

Useful when the desktop entry closes too quickly to show an error.

## `error decoding response body` / `operation timed out`

Caused by a Wine schannel bug fixed in Wine 11.6 (GE-Proton11-8 and newer). LWCompat
works around it; to check a Proton build:

```bash
tools/wine-schannel-repro/run.sh "$HOME/.local/share/Steam/compatibilitytools.d/<Proton>"
```

See the README's Troubleshooting section for details, Fast Asset Cache checks and wrong
game / Proton paths.

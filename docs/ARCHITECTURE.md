# Architecture

LWCompat 0.1.0 deliberately keeps the compatibility logic simple and close to the validated prototype.

## Components

### `start.sh`

Desktop-facing entry point. It holds a `flock` lock so repeated clicks do not start multiple concurrent game sessions.

### `lwcompat.sh`

Session supervisor. It:

1. loads the detected installation paths from `config.sh`;
2. stops any stale bridge instance;
3. patches the two launcher manifest endpoints;
4. starts the native bridge;
5. health-checks ports 18080 and 18081;
6. exports the existing Wine/Proton environment;
7. launches the official Windows launcher through UMU;
8. keeps the bridge alive until the Last War launcher/game process is gone;
9. cleans up the bridge.

### `bundle_proxy.py`

A dependency-free Python 3 bridge using `ThreadingHTTPServer` and `urllib.request`.

Two loopback listeners are created:

- `127.0.0.1:18080` for CDN / bundle traffic;
- `127.0.0.1:18081` for the version/table API.

The bridge preserves the headers needed by the launcher for normal download and resume behavior, including `Range`, `Content-Range`, `ETag`, and `Last-Modified`.

## Design constraint

The official launcher remains authoritative for game update logic. LWCompat only replaces the network transport path that has shown Wine/Proton compatibility problems.

# iOS Claude Bridge

Experimental TrollStore-only bridge for controlling selected iPadOS UI actions from iSH/Claude Code over localhost.

## MVP

The bridge listens on `127.0.0.1:8765` while the app is running.

Endpoints:

- `GET /ping` → health check
- `POST /open` with JSON `{ "bundleId": "com.google.ios.youtube" }`
- `POST /tap` with JSON `{ "x": 500, "y": 200 }`

Example from iSH:

```sh
curl http://127.0.0.1:8765/ping
curl -H 'Content-Type: application/json' -d '{"bundleId":"com.apple.Preferences"}' http://127.0.0.1:8765/open
curl -H 'Content-Type: application/json' -d '{"x":500,"y":200}' http://127.0.0.1:8765/tap
```

## Important

This is an experimental TrollStore build using private iOS APIs and private entitlements. It is intentionally not App Store compatible. Keep the bridge app in the foreground for the first tests; background persistence is a later milestone.

The HTTP server binds only to loopback (`127.0.0.1`), so it is not exposed to the LAN.

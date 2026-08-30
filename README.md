# iOS Claude Bridge

Experimental TrollStore-only diagnostic/control bridge for iSH + Claude Code. The goal is to let a terminal AI inspect an iPad, collect crash information, inspect apps/processes, and perform basic recovery actions through a localhost API.

The bridge listens only on `127.0.0.1:8765` while the app is running.

## v0.2 endpoints

- `GET /ping` — health/version
- `GET /capabilities` — supported bridge functions
- `GET /system-info` — iPadOS/kernel/memory/storage overview
- `POST /app-info` — installed app metadata and accessible container paths
- `GET|POST /processes` — process list; POST accepts `filter` and `limit`
- `GET|POST /crashlogs` — recent crash/diagnostic reports; POST can filter and include report contents
- `POST /launch` — launch an app by bundle identifier (`/open` remains an alias)
- `POST /terminate` — best-effort termination through FrontBoardServices
- `POST /tap` — secondary HID touch injection capability

## Quick tests from iSH

```sh
curl http://127.0.0.1:8765/ping
curl http://127.0.0.1:8765/capabilities
curl http://127.0.0.1:8765/system-info

curl -H 'Content-Type: application/json' \
  -d '{"bundleId":"com.apple.Preferences"}' \
  http://127.0.0.1:8765/app-info

curl -H 'Content-Type: application/json' \
  -d '{"filter":"Preferences","limit":50}' \
  http://127.0.0.1:8765/processes

curl -H 'Content-Type: application/json' \
  -d '{"limit":5,"includeContent":true,"maxBytes":65536}' \
  http://127.0.0.1:8765/crashlogs
```

A filtered crash lookup can use a filename/app-name fragment:

```sh
curl -H 'Content-Type: application/json' \
  -d '{"filter":"YouTube","limit":3,"includeContent":true}' \
  http://127.0.0.1:8765/crashlogs
```

## Scope and limitations

This is an experimental TrollStore build using private iOS APIs and private entitlements. TrollStore is not a full jailbreak, so each diagnostic/control capability must be verified on the target iPadOS version. Endpoints return explicit errors where a private API or filesystem location is unavailable.

Unified live OSLog streaming is deliberately not claimed in v0.2. The first diagnostic milestone exposes crash and diagnostic report files instead. `/capabilities` reports this limitation.

The server binds only to loopback (`127.0.0.1`), so it is not exposed to the LAN.

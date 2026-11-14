# TeamTalk NG design

## Decisions (2026-11-14)

| Topic | Decision |
| --- | --- |
| Scope | A complete rewrite. The old TeamTalk NG (built on BearWare's iTeamTalk) is scrapped; nothing of it or of BearWare's apps is reused. |
| SDK | BearWare's **official** TeamTalk 5 SDK, 5.23a (5.23.0.5209), as published. Not rebuilt or patched unless unavoidable. It isn't redistributed in this repository: `scripts/fetch-sdk.sh` downloads it, checked against pinned SHA-256s. |
| Architecture | One shared core in Rust wraps the SDK's C API (the same C library ships for iOS, Android, macOS, Windows and Linux) and holds all logic. Native interfaces on top, through UniFFI bindings (as AudioNet does). |
| Platforms | iPhone (SwiftUI), Android (Jetpack Compose), Mac (SwiftUI), Windows (native, toolkit to decide). iPhone first, then Android. |
| Identity | The same app: TeamTalk NG, same bundle IDs, Android package and signing key, so it arrives as an update. Saved servers and settings are migrated from the old app. |
| Services | The Monitor (`ngmon`, ttmonitor.mad-gamer.com) and NG Account services are kept; the core gets fresh clients for them. |
| Client name | The SDK can't set a client version (the old app patched that in); logins send the client name "TeamTalk NG", and servers show the SDK's version. |

## The core

- **One thread per server connection owns the SDK instance.** Every SDK call
  happens there; the core's API sends it commands and gets answers back. The
  thread pumps the SDK's messages (`TT_GetMessage`), keeps the model (server,
  channels, users, messages, files) up to date, and reports changes as events.
- **Commands** (`TT_Do…`) return a command ID; the server answers with
  `CMD_SUCCESS` or `CMD_ERROR` for that ID. The core turns that into a result
  for the caller, with the server's error message in words.
- **Events** are typed and complete: a UI can rebuild everything from a
  snapshot plus the events after it.
- **Text** (`TTCHAR`) is UTF-8 everywhere but Windows (UTF-16); the core
  converts at the boundary.
- **Tests** run BearWare's `tt5srv` on a random local port with a generated
  configuration, and real clients against it, including audio through the
  SDK's virtual sound device.

## Milestones

1. **The core**: connect, log in, channels, users, text messages, voice, status, reconnect; then files, administration, recording. Headless tests.
2. **iPhone app** at parity with the old one: servers, channels, users, messages, settings, sound packs, Monitor, NG Account, AudioNet, recording, admin; migration from the old app.
3. **Android app** on the same core.
4. **Mac and Windows apps**, and what neither old app had: voice activation, connection statistics, audio tuning, a microphone test, server statistics, channel operators, the full ban tools, the SDK's multi-track recording, 3D positioning.

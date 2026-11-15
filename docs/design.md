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
| App structure | Servers first; opening a server gives one screen with its channels and people, the conversation, and talk controls. Settings from a button. |
| Connections | Several servers at once, each staying connected; one core `Client` each. They share the microphone and speaker (the SDK's shared sound devices). |
| Channels | A tree, people listed under their channel; their state (talking, away, muted) is part of their name for screen readers. |
| Talking | The desktop's two modes: push to talk (a button, VoiceOver's Magic Tap, TalkBack's equivalent on Android) and voice activation (with mute). No "always on" (the desktop has none). |
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

## The SDK's trial (found 2026-11-14)

BearWare's prebuilt SDK files are trials: the SDK prints "running in TRAIL
MODE", and its documentation says the trial binaries "disable themselves
after 30 days of use" and that an end-user application needs a license
from BearWare.dk (`TT_SetLicenseInformation(name, key)` before the first
instance turns trial mode off). In trial mode the SDK runs a background
check over HTTPS (`perform_check`); a process that exits while it runs can
crash in the SDK's static destructors (seen in the test programs, after
every test has passed). BearWare's source repository (GitHub
BearWare/TeamTalk5) carries the same license agreement. The way forward is
the owner's decision.

## Mac: a fork of TTAccessible (decided 2026-11-14)

- The Mac app is a fork of TTAccessible (github.com/math65/ttaccessible,
  GPLv3, AppKit and SwiftUI) that keeps its own engine: its Swift SDK
  layer, microphone engine (TT_InsertAudioBlock into the virtual device,
  WebRTC AEC3) and its build-time SDK patches. NG's identity, Monitor, NG
  Account and other NG features are added on top, and upstream's changes
  keep being merged. The Mac app doesn't use the Rust core (for now).
- It is GPLv3, with its source published to everyone who gets it; the
  owner accepted that.
- iPhone, Android and Windows stay on the Rust core with native interfaces,
  modelled on TTAccessible: its features, settings, announcements, sound
  packs, and keyboard and screen-reader behaviour, wherever the platform
  allows.
- Every app is 100% screen-reader accessible.

## Sounds (2026-11-14)

The built-in pack is BearWare's classic TeamTalk sounds (from iTeamTalk), as
the old app shipped: the owner chose this exception to "nothing reused from
BearWare's apps". Other packs come from the catalog on ttmonitor.mad-gamer.com
(`GET /v1/catalog`, then each file from `/v1/packs/{id}/files/{name}`,
checked against the catalog's SHA-256). A pack missing a sound falls back to
the built-in one.

## The SDK, built from source (decided 2026-11-14)

The owner decided the SDK must be built from BearWare's source after all:
the prebuilt iOS SDK has no Apple silicon Simulator slice (testing a rewrite
this size needs the Simulator) and is built without FFmpeg (media files
other than WAV don't stream). Decisions:

- Source: BearWare/TeamTalk5 at the v5.23a release, pinned; BearWare's own
  build options only, no patches to their code.
- iPhone: FFmpeg on (BearWare's option) for media files; device (arm64) and
  Apple silicon Simulator (arm64) slices.
- Builds: iPhone and Simulator, Mac, Android (arm64-v8a, x86_64), and a
  Linux tt5prosrv (BearWare's encrypting server) for end-to-end encryption
  tests.
- iPhone and Simulator: done (2026-11-14) by `scripts/build-sdk-apple.sh`
  on the Mac, into `sdk/ios-src` (one library per slice, FFmpeg in it).
  BearWare's files are untouched; what it took, each through a setting
  their build already has:
  - WebRTC gets its own checkout, `~/webrtc-ttng/iOS` (BearWare's
    `WEBRTC_FETCH_PATH`): their build skips fetching when `~/webrtc/iOS`
    exists, and the old app's build had left an older WebRTC there (the
    app then missed WebRTC symbols). 5.23 pins `branch-heads/7778`.
  - WebRTC settings through BearWare's `WEBRTC_CFG_EXTRA` (a CMake cache
    file given with `-C`, FORCE, one line): `fatal_linker_warnings=false`
    (Apple's linker warns Chromium's clang has no libLTO.dylib),
    `use_clang_modules=false` and `mac_sdk_path` = the Command Line Tools'
    macOS 26 SDK: Chromium's clang can't build WebRTC's host tools with
    Xcode 27's macOS headers (float.h). Xcode's own clang can't build this
    WebRTC (it uses newer clang flags), so that route (the old app's) is out.
  - FFmpeg: BearWare's settings build arm64 for iPhones only, so for the
    Simulator a `clang` wrapper first on PATH (only FFmpeg calls clang by
    name) swaps `-miphoneos-version-min` for the Simulator's.
  - Apple's `/usr/bin/libtool` merges the libraries (GNU libtool, needed
    on PATH for the build, has the same name).
  `apps/ios/build-core.sh` uses `sdk/ios-src` when it's there, with a
  Simulator slice in the xcframework; the official SDK otherwise.
  Tested: every core test (54) runs inside the Simulator against the
  source-built SDK (`scripts/test-ios-sim.sh`), MP3 streaming included; the app
  runs in the Simulator.
- Linux: done (2026-11-15) by `scripts/build-sdk-linux.sh linux` in
  BearWare's own Docker image (Build/Docker/Dockerfile_ubuntu24), into
  sdk/linux-src (tt5srv, tt5prosrv, the libraries). tt5prosrv starts only
  with a BearWare.dk web login authorized for it: its ID and token in
  `<bearware-weblogin>` beside `<users>` (not in `<general>`), in
  tt5prosrv.xml. BearWare's built-in login address, login.bearware.dk,
  had a certificate for bearware.dk only (2026-11-15), so the token was
  got from www.bearware.dk's weblogin.php (action=auth) and kept in
  ~/.config/ttng/prosrv-bearware (mode 600; TTNG_PROSRV_BEARWARE
  overrides). tests/connecting.rs runs a whole encrypted session against
  it, and skips with a reason when either is missing.
- Android: BearWare's **official** SDK (owner agreed 2026-11-15): unlike
  the iOS one it has FFmpeg (all ABIs, x86_64 for an emulator included),
  and its standard library encrypts as a client; MP3 recording is the
  core's LAME conversion everywhere. `scripts/build-sdk-linux.sh
  android-arm64-v8a` still works if it's ever needed (BearWare's Android
  image; Google's WebRTC tools build Android only on Linux).
- Mac: not built from source (owner told 2026-11-15): BearWare's
  args.gn_mac has no WEBRTC_CFG_EXTRA hook for the Xcode 27 settings, and
  the official Mac SDK already has FFmpeg and Apple silicon.
- MP3 recordings: BearWare's SDK only encodes MP3 with Windows Media
  Foundation, so elsewhere the SDK records WAV and the core converts it to
  MP3 with LAME when the recording stops.
  Done in `ttng-core/src/mp3.rs` with the `mp3lame-encoder` crate (it
  builds LAME's own C code, LGPL; static linking on iPhone is allowed
  under the LGPL when the app's object files can be relinked, and the app
  is GPLv3 with its source available anyway). The SDK writes
  `<file>.recording.wav`; when the recording ends (stopped, left the
  channel, disconnected) it's turned into the MP3 at 128 kbit/s on its
  own thread, the WAV is deleted, and only then does RecordingChanged say
  it ended (with the error if converting failed). Recording each person:
  the SDK writes WAVs, and each becomes an MP3 when the SDK says it's
  finished (CLIENTEVENT_USER_RECORD_MEDIAFILE); if converting fails the
  WAV stays. Tests decode the MP3s (symphonia) and look for the tone.

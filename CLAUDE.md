# CLAUDE.md — TeamTalk NG

Read `docs/design.md` first: it records the decisions.

- A rewrite from scratch (2026-11-14): nothing from the old TeamTalk NG or
  BearWare's apps is reused. BearWare's SDK 5.23a: the official one,
  and for iPhone and the Simulator built from their v5.23 source
  (`scripts/build-sdk-apple.sh`, FFmpeg on, none of their files patched;
  see docs/design.md). Downloaded or built, never committed (license). Bindings are generated at build time.
- Rust workspace: `crates/ttng-sys` (bindgen), `crates/ttng-core` (the core).
  All SDK calls happen on the core's own thread; the UIs only see the core's
  API (UniFFI, later).
- Accessibility is mandatory: every state has a text form; screen reader
  users can do everything. The UIs are native (SwiftUI, Compose, …).
- Checks: `cargo test`, `cargo fmt --all -- --check`,
  `cargo clippy --all-targets -- -D warnings`. Tests run a real `tt5srv`
  from the SDK on a random local port; never a real server. On the Mac,
  `scripts/test-ios-sim.sh` runs the same tests inside the iOS Simulator
  against the SDK built from source.
  Your own Monitor end to end: `cargo test -p ttng-services --test own_monitor`
  (see docs/design.md; `crates/ng-relay` is a copy: scripts/check-ng-relay-copy.sh).
  The Monitor and NG Account against the real service:
  `NGMON_BIN=~/ng-service/target/release/ng-service cargo test -p ttng-services`
  (NG Account is only for publishing sound packs; server sync ended
  2026-11-18), and on the Mac `scripts/test-ios-ui.sh` (the app in the
  Simulator against the private service and a real ng-monitor).
- The official SDK is a trial (the owner chose to stay on it for now; see
  docs/design.md). Its trial check can segfault a test program at exit
  after every test passed: rerun; it isn't a test failure.
  `set_license(name, key)` turns trial mode off once there's a license.
- Ask before pushing, before anything that touches the stores, the old app's
  users, or the live Monitor/NG Account services.
- The UI updates immediately, everywhere (the owner's rule; it broke many
  times): every core call in ServerConnection goes through `run()` (it
  refreshes when done, since many core changes send no event) or calls
  `refresh()` itself; switches bound to anything but local state are
  `LiveToggle`; sliders are `NamedSlider` (spoken value from its own
  position). `scripts/check-ui-rules.sh` checks this (run by
  scripts/test-ios-ui.sh); new features must pass it.

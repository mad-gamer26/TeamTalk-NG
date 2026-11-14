# CLAUDE.md — TeamTalk NG

Read `docs/design.md` first: it records the decisions.

- A rewrite from scratch (2026-11-14): nothing from the old TeamTalk NG or
  BearWare's apps is reused. BearWare's **official** SDK (5.23a) only, never
  rebuilt or patched unless there's no other way; it's downloaded, never
  committed (license). Bindings are generated at build time.
- Rust workspace: `crates/ttng-sys` (bindgen), `crates/ttng-core` (the core).
  All SDK calls happen on the core's own thread; the UIs only see the core's
  API (UniFFI, later).
- Accessibility is mandatory: every state has a text form; screen reader
  users can do everything. The UIs are native (SwiftUI, Compose, …).
- Checks: `cargo test`, `cargo fmt --all -- --check`,
  `cargo clippy --all-targets -- -D warnings`. Tests run a real `tt5srv`
  from the SDK on a random local port; never a real server.
- Ask before pushing, before anything that touches the stores, the old app's
  users, or the live Monitor/NG Account services.

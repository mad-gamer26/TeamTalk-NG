# TeamTalk NG

An accessible client for [TeamTalk 5](https://bearware.dk) voice and text chat
servers, for iPhone, Android, Mac and Windows. VoiceOver-, TalkBack-, NVDA- and
JAWS-first: everything is usable without sight.

One shared core, written in Rust, wraps BearWare's official TeamTalk 5 SDK and
holds everything except the screens. Each platform has its own native
interface on top of it. See [docs/design.md](docs/design.md).

| Folder | What it is |
| --- | --- |
| `crates/ttng-sys` | Raw bindings to the SDK's C API, generated at build time from the downloaded SDK |
| `crates/ttng-core` | The core: connection, channels, users, messages, commands, events |
| `scripts/fetch-sdk.sh` | Downloads BearWare's official SDK for a platform into `sdk/` |

## Building and testing the core

```sh
scripts/fetch-sdk.sh linux      # BearWare's official 5.23a SDK, into sdk/
cargo test                      # runs a real TeamTalk server (tt5srv) for the tests
```

The SDK isn't in this repository: its license doesn't allow redistributing
it. `fetch-sdk.sh` downloads the official build and checks it against a
pinned SHA-256.

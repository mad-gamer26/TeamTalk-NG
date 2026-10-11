# TeamTalk NG

TeamTalk NG is an iPhone client for [TeamTalk 5](https://bearware.dk)
voice and text chat servers, built on BearWare.dk's TeamTalk 5 iOS client.
It adds an accessible, VoiceOver-first interface, sound packs, AudioNet
audio, and **TeamTalk NG Monitor**: a service that stays logged in to your
servers while the app is closed and sends push notifications for logins,
logouts and private messages, which you can answer from the notification.

| Folder | What it is |
|---|---|
| `Client/iTeamTalk/` | The iPhone app (Xcode project `iTeamTalk.xcodeproj`), its notification service extension and Control Center controls |
| `Client/iTeamTalk/iTeamTalk/Monitor/` | The app's side of TeamTalk NG Monitor |
| `Client/iTeamTalk/AudioNet/` | The prebuilt AudioNet engine the app links, and the script that builds it |
| `Monitor/` | `ngmon`, the Monitor service (Rust). See [Monitor/README.md](Monitor/README.md) |

## Building the app

The app needs the **TeamTalk 5 SDK for iOS** from
[bearware.dk](https://bearware.dk), which is not included here. Put its
`TeamTalk.h` and `libTeamTalk5.a` in `Library/TeamTalk_DLL/` at the top of
this repository:

```
Library/TeamTalk_DLL/TeamTalk.h
Library/TeamTalk_DLL/libTeamTalk5.a
```

Then open `Client/iTeamTalk/iTeamTalk.xcodeproj` in Xcode, choose your own
development team and bundle IDs (the app, `iTeamTalkNotifications` and
`iTeamTalkControls`, plus the app group), and build for an iPhone. The SDK
has no simulator slice.

Push notifications from the Monitor need your own APNs key and Monitor
deployment; the app points at the service in `MonitorService.baseURL`
(`Client/iTeamTalk/iTeamTalk/Monitor/MonitorClient.swift`).

## Building the Monitor service

```sh
cd Monitor
cargo build --release
cargo test
```

[Monitor/README.md](Monitor/README.md) covers its settings, API, tests
against a real TeamTalk server, and deploying it.

## License

Files with the BearWare.dk copyright header are BearWare.dk's and remain
under the TeamTalk 5 SDK License Agreement ([License.txt](License.txt)).
Everything else is under the MIT license. See [LICENSE](LICENSE).

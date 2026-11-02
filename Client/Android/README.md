# TeamTalk NG for Android

A native Android app (Kotlin, Jetpack Compose) that mirrors the iPhone app and
talks to the same TeamTalk servers and the same TeamTalk NG service. It is built
for TalkBack first, the way the iPhone app is built for VoiceOver.

## What you need

- JDK 17 or later, and the Android SDK with platform 37. On Windows, Android
  Studio's bundled JDK works.
- **TeamTalk 5.22a for Android, built with TeamTalk NG's changes**, as the iPhone
  app's library is. It's not in this repository, because of its license. See
  [Building the library](#building-the-library). It goes in
  `Library/TeamTalk_Android/` at the top of this repository, so that this file
  exists:

      Library/TeamTalk_Android/tt5sdk_v5.22a_android_ng/Library/TeamTalkJNI/libs/TeamTalk5.jar

  Somewhere else: `gradlew assembleDebug -PteamtalkSdk=/path/to/that/folder`.
  BearWare's published SDK won't do: it has no `setClientVersion`.
- **Optional: AudioNet's engine.** Without it the app builds and has no AudioNet
  button. From an [AudioNet release](https://github.com/mad-gamer26/AudioNet/releases):
  take `lib/<abi>/libaudionet_ffi.so` out of `audionet-android-<version>.apk` into
  `app/audionet/jniLibs/<abi>/`, and generate the Kotlin bindings from the same
  version of AudioNet's source into `app/audionet/java/`:

      cargo run --release -p audionet-ffi --features bindgen --bin uniffi-bindgen -- \
        generate --library target/release/libaudionet_ffi.dylib --language kotlin --no-format --out-dir app/audionet/java

  (`apps/android/build-core.ps1` in AudioNet builds both instead.) The bindings
  must match the library's version exactly.
- **Optional: `app/google-services.json`**, for Monitor notifications. Register an
  Android app with the package name `com.matthewdovi.teamtalkng` in a Firebase
  project and download the file. The build reads it directly; the google-services
  Gradle plugin isn't needed. Without it the app builds and runs, and gets no
  notifications. The service needs a service account of the same project
  (`[push.fcm]`, see [Monitor/README.md](../../Monitor/README.md)).

## Building

    gradlew assembleDebug

Point a build at another service with `-PteamtalkNgService=https://example.com`.

Release signing: put `storeFile`, `storePassword`, `keyAlias` and `keyPassword` in
`~/.teamtalkng-release/android-signing.properties` (the keystore's path relative
to that folder). Without it, release builds are unsigned.

## How it maps to the iPhone app

| iPhone | Android |
| --- | --- |
| `MainTabBarController`, `ChannelListViewController` | `ServerSession.kt`, `ui/SessionScreens.kt` |
| `ConnectedServerManager` | `SessionManager` in `SessionManager.kt` |
| `ServerListViewController`, `.tt` files, `tt://` links | `Servers.kt`, `ui/ServerScreens.kt` |
| `AudioBlockMediaStreamer`, `AudioMixing.swift` | `Streaming.kt` (decoding with MediaCodec) |
| `AudioNet.swift` | `src/audionet/.../AudioNetBridge.kt` |
| `Recording.swift` | `Recording.kt`, `ui/FileScreens.kt` |
| `ChannelFilesViewController` | `FilesScreen` in `ui/FileScreens.kt` |
| `AdminToolsViewController`, `MonitorAdmin.swift` | `ui/AdminScreens.kt`, one set of screens with an `AdminBackend` each |
| `Monitor/` | `Monitor.kt`, `MonitorModels.kt`, `MonitorNotifications.kt`, `ui/MonitorScreens.kt` |
| `Account/` | `NGAccount.kt`, `NGSync.kt`, `NGPackSync.kt`, `ui/AccountScreens.kt` |
| `UtilSound.swift`, `SoundEventsViewController` | `Sounds.kt`, `ui/SettingsScreens.kt` |
| Background audio | `ConnectionService.kt`: a foreground service with the notification Android requires, a wake lock and a Wi-Fi lock |
| Remote control events | A media session: play/pause mutes, next or previous track unmutes |
| Siri Shortcuts, Control Center control | Launcher shortcuts (`Shortcuts.kt`): hold the app's icon, or pin one from Settings |
| VoiceOver announcements | TalkBack announcements (`Speech.kt`) |
| AVSpeechSynthesizer | Android text to speech, with the same settings |
| Keychain | `SecretStore.kt`, encrypted with a key in the Android Keystore |
| QuickLook | The phone's own apps, through `ACTION_VIEW` |
| APNs and the notification extension | Firebase data messages, opened in `PushService` |
| Sounds prepared for the notification extension | One notification channel for each sound, which Android plays (`MonitorNotificationSounds`) |

Settings use the iPhone app's keys, and NG Account sync carries them between the
two apps. Sound packs, servers and monitors work the same way on both.

## Where it differs from the iPhone app

Both apps link TeamTalk 5.22a with small changes of their own: leaving your own
media stream's echo out of recordings, keeping recordings from stuttering, and
sending the app's version at login. One difference remains:

- **Live audio reaches the library differently.** The iPhone's library has a
  `ttnglive:` source for AudioNet and mixed files. Here the app serves the same
  mix as an endless WAV on `127.0.0.1`, and the library's FFmpeg streams that URL
  as a media file. The result is the same: it goes out as a media file stream and
  the microphone stays on. If the stream can't start, or the user may only
  transmit voice, the mix goes out as voice with the microphone off, as on the
  iPhone.

Also, because Android isn't iOS:

- There is no iCloud, so monitors need an NG Account here: an automatic sign-up
  would be lost with the app. Servers and settings stay on the phone without one.
- Android has no way to pick which built-in microphone is used. The choice is
  the phone's default, or a wired, USB or Bluetooth microphone.
- **Audio Output replaces Speaker Output.** Automatic plays as media, so Android
  picks headphones, Bluetooth or the speaker, and never the earpiece. Choosing a
  device uses call audio, which the library plays as a voice stream on Android
  (`teamtalk-android.patch`). It stays on the phone and isn't synced.
- **Speech Engine** lists the speech apps installed on the phone. The iPhone has
  one set of voices, so it has no such setting.

## Building the library

`teamtalk-android.patch`, which isn't in this repository because it contains
excerpts of BearWare's code, holds TeamTalk NG's changes against
[BearWare's source](https://github.com/BearWare/TeamTalk5), commit `371f460`
(SDK v5.22a). BearWare's Android build needs Linux: Ubuntu 24.04 (WSL works), the
packages in its `Build/Docker/Dockerfile_android`, and NDK r29 in
`ANDROID_NDK_HOME`. WebRTC is 35 GB and takes hours the first time.

    git checkout 371f460 && git apply teamtalk-android.patch && source env.sh
    cd Build && make CONFIGTYPE=release android-arm64-v8a android-x64

The build fetches WebRTC's `main` first, and that fails with the `depot_tools`
it uses. If it does: in `~/webrtc/Android/src`, fetch and check out
`branch-heads/6818`, run `gclient sync -D --force` in the folder above, apply
`Library/TeamTalkLib/build/webrtc/libteamtalk-r6818.patch`, delete
`CMakeCache.txt` in the build folder, and run `make` again.

Then take `Library/TeamTalkJNI/libs/<abi>/libTeamTalk5-jni.so`, run `llvm-strip
--strip-unneeded` on it, and build `TeamTalk5.jar` from
`Library/TeamTalkJNI/src` without the `TeamTalk5Pro` class.

## Testing

`adb shell am start -a android.intent.action.VIEW -d "tt://HOST?tcpport=PORT&udpport=PORT&username=NAME&password=PASSWORD"`
opens a server link. `tt5srv` comes in the TeamTalk 5 SDK for Windows or macOS,
and `Monitor/tests/fixtures/tt5srv.xml` has a test configuration. From an emulator
the host is `10.0.2.2`.

That configuration allows no file storage, so uploads are refused with "Maximum
disk usage exceeded". To test channel files, raise `max-diskusage`,
`channel-diskquota` and the channels' `diskquota`, and create the `files` folder.
Its Lobby has no audio codec either, so the Record and Audio File buttons only
appear in a channel you create with one.

To hear what TalkBack says, debug builds include a silent speech engine that logs
every utterance. Make it the default and read the log; `Tab` moves TalkBack's focus:

    adb shell settings put secure tts_default_synth com.matthewdovi.teamtalkng
    adb shell input keyevent KEYCODE_TAB
    adb logcat -s SpeechLog

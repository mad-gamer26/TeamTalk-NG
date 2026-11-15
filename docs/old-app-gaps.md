# The old TeamTalk NG app's features the new one lacks (2026-11-15)

From the old app's source (GitHub mad-gamer26/TeamTalk-NG, Mac
~/Documents/Code/TeamTalk/Client/iTeamTalk): its settings (PREF_*), screens,
extensions and strings, compared with the new app. Desktop parity is in
docs/desktop-audit.md; this list is what the old app did beyond it.

## Larger

The owner wants AudioNet and the mixing (2026-11-15), after the smaller items.

- [ ] AudioNet: sign in, pick an AudioNet device's sound and send it to the
      channel (AudioNet.swift, the audionet library).
- [ ] Audio mixing: an AudioNet sound and an audio file sent together, with
      the microphone still on, as the media file stream through a live
      source (or as voice without the right to stream); their own volumes
      (AudioMixing.swift; PREF_STREAM_AUDIONET_VOLUME, PREF_STREAM_FILE_VOLUME).
- [n/a] Translations: the owner chose English only (2026-11-15); the old
      app's 18 languages aren't carried over.
- [ ] Moving over from the old app: servers, settings, NG Account sign-in
      (planned since the start).

## Smaller

- [x] Control Center control: "Connect to Server" with a saved server
      chosen (iOS 18 ControlWidget, iTeamTalkControls).
- [x] Siri shortcuts: "Add to Siri" for connecting to a server.
- [ ] iCloud sync of settings and the server list (opt-in).
- [ ] Headset button toggles talking (remote control events).
- [x] Recordings list: play (the app's own player, in its audio session — not Quick Look, the owner's choice), share, delete the recordings in
      the app (now only through the Files app).
- [x] "Return sends message" (PREF_GENERAL_SENDONRETURN).
- [x] Files list sort field and order (PREF_FILES_SORT_*).
- [x] Speech voice language (PREF_TTSEVENT_VOICELANG; NG picks a voice).
- [ ] Monitor administration (accounts, bans, server properties through
      the Monitor, /v1/servers/{id}/admin): with monitor mode, the server
      screen's admin screens through the Monitor.
- [ ] Monitor notification sounds (MonitorNotificationSounds.swift).
- [ ] NG Account sound pack sync (Account/NGPackSync.swift: installed packs
      follow the account).

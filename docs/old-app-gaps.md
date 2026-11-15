# The old TeamTalk NG app's features the new one lacks (2026-11-15)

From the old app's source (GitHub mad-gamer26/TeamTalk-NG, Mac
~/Documents/Code/TeamTalk/Client/iTeamTalk): its settings (PREF_*), screens,
extensions and strings, compared with the new app. Desktop parity is in
docs/desktop-audit.md; this list is what the old app did beyond it.

## Larger

The owner wants AudioNet and the mixing (2026-11-15), after the smaller items.

- [x] AudioNet (AudioNet.swift): sign in as a visitor (no device added;
      the token in the keychain), the devices that share their sound,
      choose one's sound and send it to the channel, stop, sign out. The
      engine comes from an AudioNet checkout (scripts/build-audionet.sh,
      pre-linked so its libopus and Rust stay private), in its own Swift
      module (AudioNetKit). Needs the owner's AudioNet account to try.
- [x] Audio mixing (LiveMix.swift): the AudioNet sound and an audio file
      together, with the microphone still on, as the media file stream —
      without patching BearWare's SDK (the old app patched in a live
      source): the mix is written in real time, as a WAV, into a FIFO the
      SDK streams (the core doesn't probe FIFOs; tested in the core against
      tt5srv, and the Swift mix on the Mac). A file streamed while AudioNet
      sends joins the mix (pause and stop work on it); a file already
      streaming when AudioNet starts moves into it. Own volumes: AudioNet
      and file (the desktop's curve). Not done: the old app's fallback of
      sending as voice when you may not stream media files.
- [n/a] Translations: the owner chose English only (2026-11-15); the old
      app's 18 languages aren't carried over.
- [x] Moving over from the old app (OldAppImport.swift, once, before
      anything loads, when this app replaces it under the same bundle ID):
      its servers (NSKeyedArchiver "ServerList": passwords to the keychain,
      channel, channel password, status message, certificates, NG Account
      sync key), the settings both apps have (nickname, gender, status
      message, return sends, join root, usernames, message popup,
      text length, record media files) and its NG Account sign-in (its
      keychain item in the App Group, same service only). Tested in the
      Simulator with the old app's archive format. The old app's data stays.

## Smaller

- [x] Control Center control: "Connect to Server" with a saved server
      chosen (iOS 18 ControlWidget, iTeamTalkControls).
- [x] Siri shortcuts: "Add to Siri" for connecting to a server.
- [x] iCloud sync of settings and the server list (opt-in; Settings → iCloud sync, applied at the next start; passwords, sound packs and NG Account stay per device).
- [~] Headset button (MPRemoteCommandCenter, the old app's mapping): one
      press talks or stops (mutes/unmutes in voice activation), next and
      previous start, pause stops, on the open (or only) connection.
      Untested on the phone: iOS sends these to the app that's playing, and
      this one mixes with others (the owner's choice), so another app's
      audio may take them — as in the old app, which mixed too.
- [x] Recordings list: play (the app's own player, in its audio session — not Quick Look, the owner's choice), share, delete the recordings in
      the app (now only through the Files app).
- [x] "Return sends message" (PREF_GENERAL_SENDONRETURN).
- [x] Files list sort field and order (PREF_FILES_SORT_*).
- [x] Speech voice language (PREF_TTSEVENT_VOICELANG; NG picks a voice).
- [x] Monitor administration: in monitor mode the server screen's admin
      screens (user accounts, bans and channel bans, server settings,
      statistics, save configuration, broadcast) go through the Monitor's
      login (/v1/servers/{id}/admin; FFI admin_*, tested end to end), shown
      as its account's rights allow. ngmon fix (source and dev Mac only,
      not live yet): ban/unban take the ban's `type` (it refused it, so
      username and channel bans couldn't work).
- [x] Monitor notification sounds (the pack's sounds, the iPhone's, or none; Monitor screen; sounds turned off in Settings → Sounds are silent).
- [x] NG Account sound pack sync: catalog packs installed and the chosen
      pack follow the account, as the old app's settings records
      (ng_installed_catalog_packs, ng_selected_sound_pack); core
      sync_with_settings, tested. n/a: backing up packs made on the phone
      (NG has no pack maker; a sound of your own per event stays local).

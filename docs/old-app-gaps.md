# The old TeamTalk NG app's features the new one lacks (2026-11-15)

From the old app's source (GitHub mad-gamer26/TeamTalk-NG, Mac
~/Documents/Code/TeamTalk/Client/iTeamTalk): its settings (PREF_*), screens,
extensions and strings, compared with the new app. Desktop parity is in
docs/desktop-audit.md; this list is what the old app did beyond it.

## Larger

- [x] AudioNet, again (2026-11-16), in a new way (the first version,
      a mix in the media file stream, took over file streaming and was
      removed): any number of accounts, each signed in as a visitor (tokens
      in the keychain); a device's sound into a channel as a TeamTalk login
      of its own per stream (named from a template, it follows me between
      channels and sends as its voice: core insert_audio), so talking and
      file streaming are untouched; the channel's sound or my microphone to
      a device's output (core capture of the muxed and local audio); each
      stream's volume and mute shown while it streams. Needs the account to
      allow multiple logins (checked first). AudioNet.swift, AudioNetViews.swift.
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

## Sound packs (2026-11-16, the owner's choices)

- [x] Packs are made, edited, duplicated, exported and deleted
      (SoundPackViews.swift). Each sound of a pack: play, choose a file,
      or use the built-in one. Built-in and catalog packs are edited
      through a copy ("Make an editable copy"); imported and made ones
      directly. The old per-sound "your own sound" files were dropped.
- [x] Export and share: a .zip with the desktop's file names (ttng-ffi
      zip_folder); import from a folder or a .zip (unzip_flat).
- [x] Publish to the catalog through NG Account (backed up privately,
      sounds sent when changed, made public under the name and author
      given), update, withdraw; deleting a pack deletes the account's copy.
      Needs the live service's sound names to include the desktop's full
      list (deployed only to the dev Mac's ngmon so far).

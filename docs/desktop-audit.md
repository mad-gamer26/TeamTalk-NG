# Desktop detail audit (2026-11-15)

The owner's goal: NG behaves **exactly** like BearWare's desktop client
(qtTeamTalk 5.23, `Client/qtTeamTalk`), every little detail, wherever a
phone can. This is the line-by-line list of what the desktop has that NG
didn't, from its source: `settings.h` (every default), `mainwindow.ui`
(every menu item), `preferences.ui` and the other dialogs, `utiltts.h`
(spoken events), `mainwindow.cpp` (status-bar messages). docs/parity.md
is the feature table; this is the detail list. Ticked when done.

Phone equivalents: the desktop's status bar is a status line plus the chat
(the desktop logs status-bar events into the chat by default); its
right-click menus are VoiceOver actions and touch-and-hold menus (VoiceOver
lists reversed, the owner's choice); its keyboard shortcuts are hardware
keyboard shortcuts; dialogs that pop up are sheets or alerts.

## A. Defaults that differ (settings.h)

- [x] Nickname: "NoName" when empty (GENERAL_NICKNAME).
- [x] Away after inactivity: 180 seconds (GENERAL_AUTOAWAY); NG had off.
      On a phone, inactive = in the background or locked.
- [x] Channel topics in the tree: off (DISPLAY_CHANNEL_TOPIC); NG had on.
- [x] Status-bar events in the chat: on (DISPLAY_LOGSTATUSBAR); NG's
      "joins, leaves and logins in the chat" was off.
- [ ] Text message popup: on (DISPLAY_MESSAGEPOPUP): a private message
      opens its conversation (check what NG does in the foreground).
- [x] Spoken events on by default exactly as TTS_ACTIVEEVENTS: logged
      in/out, joined/left my channel, private, channel and broadcast
      messages, file added/removed, menu actions.
- [ ] Sound events: all on by default (SOUNDEVENT_ACTIVEEVENTS has all 30).

## B. Status-bar events (STATUSBAR_*), logged into the chat

- [x] The desktop's 31 status-bar events, each on/off (all on by default),
      with its templates (STATUSBARMSG_*: "{user} has logged in",
      "{user} joined channel {channel}", "Subscription \"{type}\" {state}
      for {user}", "Transmission \"{type}\" {state} for {user}", "File
      {filename} added by {user}", …) and variables, editable, as spoken
      events are; Settings → Display "Show status-bar events in the chat".
- [~] Its fixed messages (always shown) — done: connected, disconnected,
      connection lost, failed, kicked (by whom), streaming started/
      finished/aborted/error, recording to file, server configuration
      saved, cannot join channel. Still to do: connecting/connected/disconnected
      ("Connected to %1", "Disconnected from %1", "Connection lost to %1
      TCP port %2 UDP port %3", "Failed to connect to …", "Secure
      connection failed due to error …"), kicked ("Kicked from server by
      %1", "Kicked from channel by %1"), streaming ("Started/Finished/
      Aborted streaming media file to channel", "Error streaming media
      file to channel", "Streaming from %1 started"), video/desktop
      sessions, recording ("Recording to file: %1", "Writing audio file
      %1 for %2", "Finished writing to audio file %1"), "Server
      configuration saved", "Cannot join channel %1", transmission
      blocked by the operator (text, voice, media, video, desktop),
      "Voice transmission failed", "Failed to enable voice activation",
      "Link copied to clipboard", sound devices (headset in/out).
- [x] A status line on the server screen showing the latest one.

## C. Spoken events (utiltts.h): the desktop's 45, separately

- [x] Split NG's grouped events into the desktop's: subscriptions per
      type (user, channel, broadcast messages, voice, video, desktop,
      desktop input, media file, and the six intercepts), classroom per
      type (chat, voice, video, desktop, media), server connectivity,
      private typing (in the conversation) and typing anywhere, question
      mode, menu actions, voice/video/desktop transmission toggled. Same
      templates (shared per group, as the desktop).
- [ ] Output mode (speech / braille / both: VoiceOver announcement vs
      braille only) — check what iOS allows.
- [ ] "Speak selected item in lists" (TTS_SPEAKLISTS) — check meaning.
- [ ] "Use toast notification" (TTS_TOAST): a visible banner.

## D. Menus → actions

- [x] People: the whole Users menu as actions, desktop order: View / Speak
      user information, Messages, Op, Volume, Mute voice, Mute media file,
      Kick from channel, Kick and ban from channel, Kick from server,
      Kick and ban from server, each subscription and intercept (checked
      state in the name), transmit control per type, increase/lower voice
      and media volume, store for move, move, relay voice/media, mute all.
- [x] Channels: the Channels menu as actions: Join, Leave, View / Speak
      channel info, Speak channel state, Generate tt:// URL, Create,
      Update, Delete, Banned users from channel, Stream media file,
      Pause/Resume, Upload, Download, Delete file.
- [x] Speak user information, Speak channel information, Speak channel
      state (spoken through the spoken-events voice).
- [ ] Copy user information to the clipboard (userinfo.ui).
- [x] Volumes on the desktop's scale (utilsound.cpp refVolume: 0–100 on a
      curve, 50 normal, steps of 1): people's voice and media volume, the
      microphone gain, the master volume, media file vs. voice volume;
      the Volume dialog with stereo options and Default; earlier saved
      levels converted to sound the same.
- [x] Kick and ban from channel (bans from the channel, not the server).

## E. Preferences (preferences.ui)

- [x] General: push-to-talk lock (a tap starts, the next stops);
      "Restore volume settings and subscriptions on login for Web Login
      users" (on; …@bearware.dk users, by username and client); voice
      activation level 0–20, 2 by default (passed to the SDK as is).
- [ ] General: away after N seconds (NG counts minutes in the background).
- [x] Display, channel tree: the desktop's item texts exactly
      (channelstree.cpp: person "name, ✉ 😴 ❓ 🎤 💿 🎥 💻 - status, 👩 (🦸)
      (👮)", channel "name (n) or (n/all) - 👻 - 🔒: topic"), style emoji
      (default) / text / none, show number of users (on), show last to
      talk in yellow (on), show icons (on), maximum text length 50 (shown
      text cut, VoiceOver gets all), sort ascending / popularity, unread
      private messages marked.
- [x] Display: timestamp format (empty: the system's short date and
      time); dialogs: text message popup (on: a private message opens its
      conversation), excluded from channel/server (off: an alert), server
      list on startup (off). n/a: the transfer dialog (NG has none), the
      MOTD dialog (NG shows it in the chat, as the desktop's default).
- [x] Sound events: playback mode (Default, One by One, Overlapping).
- [ ] Sound system: "Test selected" (play a test through the output).

## F. Dialogs

- [x] Status: "Display file name in status message when streaming"; a
      paused stream shown (💿⏸️ / "Streaming mediafile (Paused)").
- [x] New channel: "Join channel on exit" (checked; made and joined).
- [x] Server entry: "Show password" (and the channel's).
- [x] Server list: filter by name and user count; official/unofficial.
- [ ] Server list: export the list to a .tt file; latest hosts.
- [ ] Volume: "Default" buttons.
- [x] Stream media file: the dialog with the file's properties,
      "Continuously play media file", start position.
- [ ] Stream media file: audio preprocessor (none / TeamTalk / Speex /
      WebRTC), test playback, video codec bitrate (core work).
- [x] Online users: "Keep disconnected users" (off).
- [ ] File transfer: "Close when completed"; open the file when done.
- [ ] Banned users: ban by hand with a ban type; unban lists.
- [ ] Record: stream types, separate folders for channel and private logs.

## G. Behaviour details (mainwindow.cpp) — reading in progress

- [x] Server errors in the desktop's words (every CMDERR_*, in the core,
      so all apps say the same); a wrong login opens "Login error" to
      correct the username and password and try again (saved); a wrong
      channel password asks again ("Join channel error"); kicked (status,
      the desktop's words, the optional dialog); "… blocked by channel
      operator" when talking, writing to the channel or streaming isn't
      allowed (the desktop's canTx: classroom lists allow, others block).
- [ ] Still to read: file transfer done, new video/desktop session,
      desktop access requests, sound devices (headset in and out).

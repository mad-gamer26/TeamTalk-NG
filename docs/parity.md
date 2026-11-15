# Parity with the desktop clients

The goal (owner, 2026-11-14): the mobile apps have **the same features as
BearWare's desktop clients**, wherever a phone can do it. Reference: the
TeamTalk 5 client (Qt, `Client/qtTeamTalk`) and TeamTalk Classic (Windows,
`Client/TeamTalkClassic`) in github.com/BearWare/TeamTalk5. They have the same
feature set; Classic adds Position Users and a setup wizard. Their code isn't
copied, only their features. Everything is screen-reader accessible, polished,
and tested against a real `tt5srv`.

Status: **done**, **partial** (what's missing is said), **todo**, or **n/a**
(no phone equivalent, with why). Numbers are the batches below.

## Client menu

| Desktop | NG |
|---|---|
| Sound configuration: input/output devices, refresh | done on iPhone: speaker or earpiece, Bluetooth headset microphones, choice of microphone |
| Echo cancellation, automatic gain control, denoising | done (WebRTC, as the desktop; duplex devices for echo cancellation; a channel's fixed volume sets the gain) |
| New client instance | done: several servers at once |
| Connect | done |
| Preferences | partial: see Preferences |
| Record conversations to disk | done: one file and/or a file per person, with media files, MP3 or WAV, chat logs as text files. The SDK makes MP3s only on Windows, so the core records WAV and converts with LAME (tested by decoding the MP3s) |
| Speak client statistics | done (Connection statistics, the ping announced) |
| Exit | n/a (iOS apps aren't quit); Disconnect per server is done |

## Me menu

| Desktop | NG |
|---|---|
| Text-to-speech events on/off, sound events on/off | done (every sound event and spoken event, each on or off) |
| Change nickname | done (per server, and while connected) |
| Change status | done |
| Toggle question mode | done |
| Gender (status flags) | done (kept apart from the status mode) |
| Hear myself | done |
| Push to talk, voice activation | done (with always on, Magic Tap) |
| Video transmission | n/a on phones (see Video below) |
| Desktop sharing | n/a: iOS can't share the screen to TeamTalk this way |

## Users menu

| Desktop | NG |
|---|---|
| Subscriptions: user, channel, broadcast messages, voice, video, desktop, desktop access, media file | done |
| Intercept: user messages, channel messages, voice, video, desktop, media file | done (admins). The SDK gives intercepted private messages as addressed to me, so their real recipient isn't shown |
| Voice volume up/down, media file volume up/down | done (sliders in 10% steps, up to 400%) |
| Stereo: mute left/right | done, for voice and media files |
| Store for move, move users, move dialog | done (pick several, move them together) |
| Relay voice/media stream | done |
| Mute voice, mute media file | done |
| Mute all | done |
| Kick from channel/server | done |
| Kick and ban from channel/server | done (by account or IP address) |
| View/speak user information | done (a Person screen: everything, with statistics) |
| Transmit control (classroom): allow chat, voice, video, desktop, media per person and for all | done |
| Messages | done (private messages) |
| Allow desktop access | n/a with desktop sharing |
| Op (channel operator) | done (also with the channel's operator password) |
| Position users (Classic) | done: left/right per person; n/a: 3D positions (SDK 5.23 marks SOUNDDEVICEFEATURE_3DPOSITION deprecated: no sound system supports it any more, the desktop's included) |

## Channels menu

| Desktop | NG |
|---|---|
| View/speak channel info and state | done (Channel information: everything, in words) |
| Stream media file to channel, pause/resume | done (from Files: pause, resume, 10 s back and forward, stop; looping in the core) |
| Join, leave | done |
| tt:// URL | done: copy one for any channel, and tt:// links open the app |
| Create, update, delete | done: every setting (operator password, disk quota, Opus codec settings, fixed volume, time limits, every type), and joining hidden channels by path |
| Channel bans | done (list and remove) |
| Upload, download, delete file | done |
| View channel messages (Classic) | done (Chat) |

## Server menu

| Desktop | NG |
|---|---|
| User accounts: list, add, edit, delete (type, rights, initial channel, auto-operator channels, bitrate limit, flood protection, note) | done (and the initial channel is joined after login, as the desktop does) |
| Banned users | done: list, search, remove, ban an address (wildcards) by hand |
| Online users (with those who left) | done |
| Broadcast message | done |
| Server properties | done: every setting, and the version |
| Save configuration | done |
| Server statistics | done |

## Help menu

| Desktop | NG |
|---|---|
| Manual | done (Help) |
| Reset preferences | done |
| Website, check for update, about | done: About with the website; n/a: updates (the App Store) |
| Setup wizard (Classic) | done (first-run setup: nickname, gender, talking, a first server) |

## Preferences

| Desktop tab | NG |
|---|---|
| General: nickname, gender, away after inactivity, status messages, BearWare web login, push to talk / voice activation, key combination | done: nickname, gender, status message, away after a while in the background or locked (its own message, voice activation paused), talk modes; n/a: global hotkeys (iOS); keyboard shortcuts done |
| Display: language, timestamps, chat as list, window title, message templates (done), status events in chat, channel tree (user counts, username vs nickname, last to talk, topics, sort, double-tap action), popups, MOTD dialog, updates | done: timestamps, events in chat, usernames or nicknames, topics, sorting, the double-tap action (join or leave, the desktop's default), collapsing and expanding channels as the desktop does (new ones collapsed or, with "Expand channels automatically", expanded; the one I join expanded with its parents; the one I leave collapsed; headings with an arrow and Expand/Collapse actions), the MOTD in the chat, notifications for private messages in the background (the popup); chat is always a list; n/a: language (the system's), window title, tray, always on top, updates (the App Store) |
| Connection: connect to last on start, reconnect, join root, max payload, default subscriptions, local ports | done: connect on start (per server), reconnect, join root, default subscriptions; n/a: local ports, max payload (the SDK handles it) |
| Sound system: devices, AEC, AGC, denoise, media vs voice volume | done (plus microphone gain and output volume) |
| Sound events: pack, volume, per-event files, enable all/clear all | done: every desktop event (31) with the desktop's sounds built in, packs, volume, a file of your own per event, all on, all off, revert |
| Text to speech: per-event messages with variables, voice, rate, volume, interrupt, output mode | done: the desktop's 20 events with its messages and {variables}, editable, through VoiceOver or the system voice (voice, speed, volume), interrupting or not |
| Shortcuts | done for a hardware keyboard (talk, mute everyone, the tabs, send) |
| Video capture: device, resolution, format, codec | n/a on phones (no video capture in the SDK there) |

## Server entries and connecting

| Desktop | NG |
|---|---|
| Name, host, ports, encrypted, username, password, nickname, status message, channel and its password | done (kept in the old app's NG Account fields, so they sync) |
| Encryption setup: CA, client certificate and key, verify server | done (imported from Files; certificate checking tested against a TLS server; BearWare's standard SDK server doesn't encrypt, so a whole encrypted session isn't tested here) |
| BearWare.dk web login | done (sign in once; servers with the username "bearware" log in with it; tested against a stand-in for bearware.dk) |
| Join code, last joined channel | done |
| .tt files and tt:// links: open, generate | done (import and share .tt files; open and copy links) |
| Public server list | done (official, public, and unofficial when asked) |

## Text messages

| Desktop | NG |
|---|---|
| Typing indicators | done (sent while writing privately, shown, sounded and spoken as on the desktop) |
| Message templates and timestamps | done: timestamps on or off; the desktop's nine chat templates with its defaults and variables, editable, used when "Format the chat as the desktop does" is on (with its server name, joined channel, topic and disk quota lines) |
| Message logs to files | done |

## Video and desktop

| Desktop | NG |
|---|---|
| See others' video and shared desktops | done: camera, streamed video and shared desktops, each as an image VoiceOver can describe (tested: a desktop arrives pixel for pixel; a streamed video's pictures arrive) |
| Send camera video | n/a on phones: BearWare's SDK captures video only on Mac, Windows and Linux and can't take frames from outside |
| Stream video files | done (VP8; a setting). The Linux SDK decodes VP8/WebM video but not H.264's pictures; iPhone untested |

## Batches (in order)

1. **People** (done): subscriptions and intercepts, media volume, stereo, mute media,
   mute all, hear myself, user information, operator, classroom permissions,
   channel bans, moving several people, relaying, positioning.
2. **Me** (done): nickname while connected, question mode, gender, away.
3. **Channels** (done): channel information, every channel setting, channel bans
   list, streaming files to the channel.
4. **Server administration** (done): user accounts, online users, all server
   properties, save configuration, statistics, bans by address.
5. **Sound and recording** (done): audio routes, echo cancellation, gain, denoising,
   media vs voice volume, client statistics, recording options, text logs.
6. **Preferences** (done): every desktop sound event, spoken events with templates,
   display and connection options, reset.
7. **Connecting** (done): encryption certificates, web login, join codes, tt:// and
   .tt files, public server list, status message and channel password per
   server.
8. **Typing indicators** (done).
9. **Video** (done, receiving; sending the camera is n/a): seeing it, sending the camera, streaming video files.
10. **Help and polish** (done): About, help, first-run setup, keyboard shortcuts.

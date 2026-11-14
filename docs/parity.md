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
| Sound configuration: input/output devices, refresh | todo (5): iOS audio routes (speaker, earpiece, Bluetooth, wired), chosen in the app |
| Echo cancellation, automatic gain control, denoising | todo (5) |
| New client instance | done: several servers at once |
| Connect | done |
| Preferences | partial: see Preferences |
| Record conversations to disk | partial: one file of my channel; todo (5): separate file per person, voice and media streams, folder, text logs |
| Speak client statistics | todo (5) |
| Exit | n/a (iOS apps aren't quit); Disconnect per server is done |

## Me menu

| Desktop | NG |
|---|---|
| Text-to-speech events on/off, sound events on/off | partial: sounds per event done; todo (6): spoken events chosen per event with templates |
| Change nickname | done (per server, and while connected) |
| Change status | done |
| Toggle question mode | done |
| Gender (status flags) | done (kept apart from the status mode) |
| Hear myself | done |
| Push to talk, voice activation | done (with always on, Magic Tap) |
| Video transmission | todo (9): camera |
| Desktop sharing | n/a: iOS can't share the screen to TeamTalk this way |

## Users menu

| Desktop | NG |
|---|---|
| Subscriptions: user, channel, broadcast messages, voice, video, desktop, desktop access, media file | done |
| Intercept: user messages, channel messages, voice, video, desktop, media file | done (admins). The SDK gives intercepted private messages as addressed to me, so their real recipient isn't shown |
| Voice volume up/down, media file volume up/down | done (sliders in 10% steps, up to 400%) |
| Stereo: mute left/right | done, for voice and media files |
| Store for move, move users, move dialog | partial: move one person; todo (1): several at once |
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
| Position users (Classic) | partial: left/right per person; todo: 3D positions |

## Channels menu

| Desktop | NG |
|---|---|
| View/speak channel info and state | done (Channel information: everything, in words) |
| Stream media file to channel, pause/resume | done (from Files: pause, resume, 10 s back and forward, stop; looping in the core) |
| Join, leave | done |
| tt:// URL | todo (7): make one, open one |
| Create, update, delete | done: every setting (operator password, disk quota, Opus codec settings, fixed volume, time limits, every type), and joining hidden channels by path |
| Channel bans | done (list and remove) |
| Upload, download, delete file | done |
| View channel messages (Classic) | done (Chat) |

## Server menu

| Desktop | NG |
|---|---|
| User accounts: list, add, edit, delete (type, rights, initial channel, auto-operator channels, bitrate limit, flood protection, note) | done (and the initial channel is joined after login, as the desktop does) |
| Banned users | done: list, remove, ban an address (wildcards) by hand; todo: search |
| Online users (with those who left) | done |
| Broadcast message | done |
| Server properties | done: every setting, and the version |
| Save configuration | done |
| Server statistics | done |

## Help menu

| Desktop | NG |
|---|---|
| Manual | todo (10): in-app help |
| Reset preferences | todo (6) |
| Website, check for update, about | todo (10): About; updates come from the App Store |
| Setup wizard (Classic) | todo (10): first-run setup |

## Preferences

| Desktop tab | NG |
|---|---|
| General: nickname, gender, away after inactivity, status messages, BearWare web login, push to talk / voice activation, key combination | partial: nickname, talk modes; todo (2, 7): gender, away after locking or inactivity, web login; n/a: global hotkeys (iOS; hardware keyboard shortcuts todo (10)) |
| Display: language, timestamps, chat as list, window title, message templates, status events in chat, channel tree (user counts, username vs nickname, last to talk, topics, sort, double-tap action), popups, MOTD dialog, updates | partial: chat list with times; todo (6): timestamps, what the tree shows and how it sorts, MOTD on connect, events in chat; n/a: tray, always on top |
| Connection: connect to last on start, reconnect, join root, max payload, default subscriptions, local ports | partial: reconnect; todo (6): the rest |
| Sound system: devices, AEC, AGC, denoise, media vs voice volume | todo (5) |
| Sound events: pack, volume, per-event files, enable all/clear all | partial: packs, volume, per event; todo (6): every desktop event (sent messages, voice activation, question mode, mute all, typing, transmit queue, new video/desktop, intercept), a file per event |
| Text to speech: per-event messages with variables, voice, rate, volume, interrupt, output mode | todo (6): through VoiceOver (announcements) or the system voice |
| Shortcuts | todo (10): hardware keyboard |
| Video capture: device, resolution, format, codec | todo (9) |

## Server entries and connecting

| Desktop | NG |
|---|---|
| Name, host, ports, encrypted, username, password, nickname, status message, channel and its password | partial: status message and channel password todo (7) |
| Encryption setup: CA, client certificate and key, verify server | todo (7) |
| BearWare.dk web login | todo (7) |
| Join code, last joined channel | todo (7) |
| .tt files and tt:// links: open, generate | todo (7) |
| Public server list | todo (7) |

## Text messages

| Desktop | NG |
|---|---|
| Typing indicators | todo (8) |
| Message templates and timestamps | todo (6) |
| Message logs to files | todo (5) |

## Video and desktop

| Desktop | NG |
|---|---|
| See others' video and shared desktops | todo (9): described for screen readers (who's sharing), shown for others |
| Send camera video | todo (9) |
| Stream video files | todo (9) |

## Batches (in order)

1. **People**: subscriptions and intercepts, media volume, stereo, mute media,
   mute all, hear myself, user information, operator, classroom permissions,
   channel bans, moving several people, relaying, positioning.
2. **Me**: nickname while connected, question mode, gender, away.
3. **Channels**: channel information, every channel setting, channel bans
   list, streaming files to the channel.
4. **Server administration**: user accounts, online users, all server
   properties, save configuration, statistics, bans by address.
5. **Sound and recording**: audio routes, echo cancellation, gain, denoising,
   media vs voice volume, client statistics, recording options, text logs.
6. **Preferences**: every desktop sound event, spoken events with templates,
   display and connection options, reset.
7. **Connecting**: encryption certificates, web login, join codes, tt:// and
   .tt files, public server list, status message and channel password per
   server.
8. **Typing indicators.**
9. **Video**: seeing it, sending the camera, streaming video files.
10. **Help and polish**: About, help, first-run setup, keyboard shortcuts.

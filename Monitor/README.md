# TeamTalk NG Monitor (`ngmon`)

The central service behind TeamTalk NG's **Monitors**, running at
`https://ttmonitor.mad-gamer.com`. Nobody hosts their own. In the app, a
person chooses **Monitor This Server** on a saved server, and the service
logs in to that server with its saved login. From then on it stays logged in
around the clock, like [TTCom](https://dlee.org/ttcom), so the app can:

- notify them when people log in or out, message them, mention them in a
  channel, or broadcast;
- reply to private and channel messages, straight from the notification;
- show who is on the server and where, and act on it: join channels, send
  messages and broadcasts, move, kick and ban people, change the monitor's
  nickname and status.

It speaks TeamTalk's text protocol (TCP, plain or TLS), so it needs no
TeamTalk SDK and no audio. Other users see it as a text client named
"<nickname> (Monitor)".

```
TeamTalk servers ◄── TCP/TLS ── ngmon ◄── nginx (HTTPS, WebSocket) ◄── TeamTalk NG
                                  │
                                  └── APNs (the team's key) ──► phones
```

## How people use it

1. Each app install signs itself up the first time its owner monitors a
   server (`POST /v1/register`). It gets a secret token and a push key, and
   there is nothing to configure.
2. Every server belongs to the install that added it. An install can only
   see and act on its own servers, events and messages. Other installs'
   servers answer "not found".
3. When someone connects to a monitored server live with the same account,
   the app pauses the monitor for that server and resumes it when they
   disconnect. The pause is renewed every 5 minutes and lasts at most 15,
   so it ends by itself if the app is closed. If the server allows one
   login per account and the monitor is still thrown off, it steps aside
   quietly, waiting 2, 5, 10, then 15 minutes, instead of fighting for the
   login.
4. **Stop Monitoring All Servers** in the app deletes the install, its
   servers, logins and messages.
5. **Deleting the app or changing iPhones.** The sign-up is saved in iCloud
   Keychain, so a reinstalled app or a new iPhone with the same Apple ID
   finds its monitors again. Each copy of the app registers for
   notifications on its own (`install_id`), so every iPhone gets them.
   The install ID starts over on a new iPhone, even one restored from a
   backup, so two phones never share it. If a new iPhone signs up before
   iCloud Keychain brings the old sign-up, the app merges the newer one
   into the older (`POST /v1/me/merge` with the other's token). Its
   servers, conversations and phones move over.
6. **Abandoned sign-ups.** The service tracks when the app last made
   contact. The notification extension also checks in at most once a day,
   so someone who only reads notifications counts as active.
   - **Daily silent check:** once a day, each iPhone gets a silent
     background push that shows nothing. Apple refuses it when the app has
     been deleted, so a deletion is noticed within a day, even on a quiet
     server.
   - **Asleep:** a sign-up goes to sleep, and its monitors log out of their
     servers, one day after the app is gone from every iPhone. With no way
     to tell (notifications never allowed), it sleeps after 14 days without
     contact.
   - **Waking:** any contact from the app wakes it at once.
   - **Deleted:** after 180 days without contact the sign-up is deleted,
     with its servers, stored logins and messages.

   The service does all this hourly. `ngmon check-phones` and
   `ngmon sweep` run them now.

## Safety and limits

- **No private addresses.** The service only connects to servers on the
  internet: private, loopback, link-local and similar addresses are refused.
  Otherwise anyone could use it to reach the monitor's own machine or
  network. (`mad-gamer.com` itself is allowed, because people's servers run
  there. Only ports already open to the internet are reachable through its
  public address.) `allow_private_hosts = true` turns this off, for tests
  only.
- **Limits:** 10 servers per install, 2000 in all, and 20 new installs per
  address per hour (see `[limits]`).
- **Stored logins.** The monitor needs the real server passwords to log
  in, so they cannot be hashed. They are encrypted in `data/ngmon.sqlite`
  (ChaCha20-Poly1305) with a key in `secret.key` next to the settings
  file (`secret_key_file`), made on first start and readable only by the
  service's account. A copy of the database alone reveals no passwords.
  Back the key up separately: without it every monitor's login must be
  entered again. The API never sends passwords out, and the service runs
  with `UMask=0077`.
- **Sealed notifications.** Notification text is sealed with a key only
  the install has. Apple sees "New activity on a monitored server", and the
  app's notification service extension opens the real text on the phone.
- **TLS certificates.** Encrypted TeamTalk servers' certificates are not
  checked, because they are almost always self-signed. This matches
  TeamTalk clients' default.

## Deploying

First copy `deploy/example/` to `deploy/site/` (git ignores it) and fill
it in: `site.env` says where the monitor goes, `ngmon.toml` holds its
settings and your APNs key's location (a `.p8` key from your Apple
developer account, for your app's bundle ID), and `ngmon.service` and
`nginx.conf` are the systemd unit and nginx site. Then:

```sh
deploy/deploy.sh
```

This copies the source to `~/ngmon` on `NGMON_HOST`, builds it there and
installs `bin/ngmon`. The first time, it also installs:

- the settings file (`deploy/site/ngmon.toml` becomes `~/ngmon/ngmon.toml`);
- the systemd unit (`deploy/site/ngmon.service`);
- the nginx site (`deploy/site/nginx.conf`, as `NGMON_NGINX_SITE`).

It then restarts the service and checks `NGMON_URL/v1/info`. The app talks
to the service at `MonitorService.baseURL` in `MonitorClient.swift`.

On the server:

```sh
cd ~/ngmon
bin/ngmon -c ngmon.toml stats                 # installs and servers
bin/ngmon -c ngmon.toml servers               # every monitored server
bin/ngmon -c ngmon.toml device list           # installs
bin/ngmon -c ngmon.toml device remove <id>    # forget an install and its servers
bin/ngmon -c ngmon.toml push-test --device <id>   # test notification to a phone
journalctl -u ngmon -f                        # log (NGMON_LOG=ngmon=debug for more)
```

## Behaviour worth knowing

- **Logins.** The monitor stays out of channels unless told to join one
  (from the app). To read a channel's messages and reply there, it must be
  in that channel.
- **Reconnecting.** It reconnects by itself with a growing delay (2 s up to
  1 minute). If the server refuses the login, it waits 5 minutes between
  tries. Its owner is notified when a server has been lost for over a
  minute, but not when the monitor stepped aside or was paused.
- **Event log.** Events are numbered. The app resumes from the last one it
  saw, so nothing is missed while it is closed. The newest 5000 events per
  server are kept.
- **Private messages.** Conversations work as they do in TeamTalk. A
  conversation is with one user ID for as long as that person stays logged
  in. When they log out, it ends and keeps its history. Their next login is
  a new conversation, and so is the same ID after a server restart. A reply
  can name its conversation (`conversation_id`), and the service refuses
  it once that conversation has ended, so it never reaches whoever has the
  ID now.
- **Long messages.** Messages over 511 characters are split into parts and
  joined again on arrival, as TeamTalk clients do.

## API (v1)

All JSON. `Authorization: Bearer <token>` on everything but `/v1/info` and
`/v1/register`.

| Method and path | Purpose |
|---|---|
| `GET /v1/info` | Service name and API version |
| `POST /v1/register` `{device_name}` | Sign up an install; returns `token`, `push_key`, `device_id` |
| `GET/PATCH/DELETE /v1/me` | This install; rename; forget it and everything it monitored |
| `PUT /v1/me/push` `{apns_token, sandbox, app_ref}` | Register for pushes (`app_ref` comes back in each push as `ttng.ref`) |
| `GET/PUT /v1/me/prefs` | Notification preferences |
| `GET/POST /v1/servers` | This install's servers with status; monitor one (`status_mode` carries the monitor's gender: 256 female, 4096 neutral, 0 male; changing it, `status_msg` or `nickname` applies without logging in again) |
| `GET/PUT/DELETE /v1/servers/{id}` | Full live state (`server`, `state`, `seq`); change; stop monitoring |
| `GET /v1/servers/{id}/config` | Settings without passwords |
| `POST/DELETE /v1/servers/{id}/pause` `{minutes}` | Pause monitoring (at most 12 hours); resume |
| `POST /v1/servers/{id}/messages` | `{to: "user", user_id, conversation_id?}`, `{to: "channel", channel_id?}` or `{to: "broadcast"}`, plus `text` |
| `POST /v1/servers/{id}/admin` `{command, params}` | Manage the server: `listaccounts`, `newaccount`, `delaccount`, `listbans`, `ban`, `unban`, `updateserver`, `querystats`, `saveconfig`, with their own fields only; returns the server's answer as `lines` |
| `POST /v1/servers/{id}/actions` | `{action: "join", channel_id or channel, password?}`, `leave`, `move {user_id, channel_id}`, `kick {user_id, channel_id?}`, `ban {user_id}`, `nickname {nickname}` (also saved in the server's settings), `status {status_mode, status_msg}` (keeps the monitor's gender unless `status_mode` gives one; also saved in the server's settings) |
| `GET /v1/conversations?server_id=` | Private conversations (`id`, `user_id`, `nickname`, `active`, unread count) |
| `GET /v1/servers/{id}/conversations/{conversation}/messages?before=&limit=` | A conversation and its history |
| `POST /v1/servers/{id}/conversations/{conversation}/read` | Mark read |
| `DELETE /v1/servers/{id}/conversations/{conversation}` | Delete a conversation and its messages |
| `GET /v1/events?since=&server_id=&limit=` | Event history (`gap: true` if `since` is older than the log) |
| `GET /v1/ws?since=` | WebSocket: missed events, then `{"type":"ready"}`, then live `{"type":"event"}` messages. `{"type":"reset"}` means reload. |

A server's `status` is one of `connecting`, `connected`, `logged_in`,
`disconnected`, `login_failed`, `stepped_aside` or `paused`, with a `reason`
in plain words.

Errors are `{"error": "<what went wrong>"}` with these statuses:

- 400: the request is invalid, or the address isn't allowed;
- 401: the install is unknown;
- 404: no such server, or not this install's;
- 409: the monitor can't do that right now, or a limit was reached;
- 422: the TeamTalk server refused;
- 429: too many sign-ups;
- 503: the TeamTalk server didn't answer.

## NG Account

An NG Account (email and password) owns a person's monitors, synced
servers and settings, and sound packs, so a new iPhone or a reinstall only
needs signing in. It replaces iCloud sync and the iCloud Keychain sign-up.

- **Signing up** emails a 6-digit code (through `[mail]`), typed into the
  app to finish. Resetting a password works the same way. Passwords are
  hashed with Argon2. Codes expire after 15 minutes and stop working after
  5 wrong tries. 10 wrong passwords in a row lock the account for 15
  minutes. Codes, sign-ins and sign-ups are also limited per network and
  per address.
- **The account owns one sign-up**, the same kind of owner an install
  without an account has, so monitoring, notifications and conversations
  work as before. Each app install that signs in gets its own session,
  which ends at sign-out (and its pushes stop). The first sign-in brings an
  older sign-up's token (`claim_token`), and that sign-up's monitors become
  the account's.
- **Sync** keeps revisioned records (`server`, `setting`) per account. The
  app pulls changes since a revision and pushes its own with the revision
  each was based on. A change made elsewhere meanwhile comes back as a
  conflict. Server passwords, channel passwords and client certificate
  keys are encrypted at rest. Other installs hear of changes over the
  WebSocket (`{"type":"sync"}`) or a silent push (`ttng.sync`).
- **Sound packs** back up privately. Files are kept once, named by SHA-256,
  under `packs_dir`. A pack can be at most 25 MB, and an account's packs
  250 MB. Publishing needs a pack name and the name shown as its maker.
  Deleting an account removes its private packs, and its public ones stay
  in the catalog, owned by nobody.
- **Account sign-ups are never deleted for inactivity.** They only go
  dormant; the account decides when they're deleted.

| Method and path | Purpose |
|---|---|
| `POST /v1/account/signup` `{email, password}` | Email a code to finish with |
| `POST /v1/account/verify` `{email, code, install_id, device_name, claim_token?}` | Make the account and sign in: `token`, `push_key`, `device_id`, `account` |
| `POST /v1/account/signin` `{email, password, install_id, device_name, claim_token?}` | Sign in |
| `POST /v1/account/forgot` `{email}` | Email a reset code (the same answer whether or not the account exists) |
| `POST /v1/account/reset` `{email, code, password, install_id, device_name}` | New password; signs out every other install |
| `GET /v1/account` | The account, its sync revision and sound pack usage |
| `POST /v1/account/password` `{current, new}` | Change the password; signs out other installs |
| `GET /v1/account/sessions`, `DELETE /v1/account/sessions/{id}` | Signed-in installs; sign one out |
| `POST /v1/account/signout` | Sign this install out |
| `POST /v1/account/delete` `{password}` | Delete the account and everything only it has |
| `GET /v1/account/export` | Everything, as JSON, without passwords |
| `GET /v1/sync?since=`, `POST /v1/sync` `{changes}` | Pull and push synced records |
| `GET/POST /v1/packs`, `PATCH/DELETE /v1/packs/{id}` | The account's packs; back one up `{local_id, name}`; change or publish `{name, author, description, public}` |
| `PUT/DELETE/GET /v1/packs/{id}/files/{name}` | A sound (`logged_on.wav`; only known sounds, checked to be audio) |
| `GET /v1/packs/{id}/pack.zip` | A whole pack (the owner's, or a published one) |
| `GET /v1/catalog?q=&sort=popular` | Published packs, Official ones first (no token needed) |
| `POST /v1/catalog/{id}/installed`, `POST /v1/catalog/{id}/report` `{reason}` | Count an install; report a pack |

On the server:

```sh
bin/ngmon -c ngmon.toml account list
bin/ngmon -c ngmon.toml account block <id>      # can't publish; unpublishes its packs
bin/ngmon -c ngmon.toml pack list               # every pack, private ones too
bin/ngmon -c ngmon.toml pack reports
bin/ngmon -c ngmon.toml pack hide <id>          # take out of the catalog (show <id> to undo)
bin/ngmon -c ngmon.toml pack import-official <id> <name> <author> <version> <zip>
```

The test `tests/accounts_e2e.py` covers all of this against a running
monitor, with email written to a folder.

## Tests

```sh
cargo test                                         # protocol, state, storage, push, safety
python3 tests/e2e.py --tt5srv /path/to/tt5srv      # against a real TeamTalk server
python3 tests/accounts_e2e.py                      # NG Account: accounts, sync, sound packs
tests/app_check/build.sh && python3 tests/app_check/drive.py /path/to/tt5srv
```

`tests/e2e.py` starts a TeamTalk server with `tests/fixtures/tt5srv.xml`, a
stand-in for Apple's push service and `ngmon`. It then plays TeamTalk users
and two app installs against them. It covers:

- installs kept apart;
- limits;
- live events and catching up on missed ones;
- sealed pushes;
- replies and channel actions;
- reconnecting;
- a one-login account shared with the "phone" (stepping aside, pausing);
- an install forgetting itself.

`tests/app_check` compiles the app's own monitor code
(`Client/iTeamTalk/iTeamTalk/Monitor`) for Mac Catalyst and drives it against
the same setup. The TeamTalk SDK has no simulator build, so this is how the
app's networking, decoding and push opening are tested off the phone.
`tt5srv` comes in the TeamTalk 5 SDK download from bearware.dk.

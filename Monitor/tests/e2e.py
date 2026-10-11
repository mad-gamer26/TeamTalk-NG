#!/usr/bin/env python3
"""End-to-end test of ngmon against a real TeamTalk server.

Runs `ngmon serve` against a TeamTalk 5 server set up with
tests/fixtures/tt5srv.xml, plays other TeamTalk users over the text
protocol, uses the API and WebSocket as two TeamTalk NG installs would, and
catches push notifications with a stand-in for Apple's push service.

    cargo build
    python3 tests/e2e.py --tt5srv /path/to/tt5srv     # starts its own server
    python3 tests/e2e.py                              # server already on 127.0.0.1:20333

Needs: requests, websockets, cryptography.
"""

import argparse
import base64
import http.server
import json
import os
import queue
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time

import requests
from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305
from websockets.sync.client import connect as ws_connect

HERE = os.path.dirname(os.path.abspath(__file__))
TT_PORT = 20333
API = "http://127.0.0.1:18650"
APNS_PORT = 18651
FAKE_APNS_TOKEN = "ab" * 32


def check(cond, what):
    if not cond:
        raise AssertionError(what)
    print("  ok:", what)


def wait_for(fn, what, timeout=15.0):
    end = time.time() + timeout
    while time.time() < end:
        v = fn()
        if v:
            print("  ok:", what)
            return v
        time.sleep(0.2)
    raise AssertionError("timed out: " + what)


class TTUser:
    """Someone on the TeamTalk server, speaking the text protocol."""

    def __init__(self, nickname, username, password):
        self.sock = socket.create_connection(("127.0.0.1", TT_PORT))
        self.file = self.sock.makefile("rb")
        self.lines = queue.Queue()
        self.next_id = 1
        welcome = self.file.readline().decode()
        assert welcome.startswith("teamtalk "), welcome
        threading.Thread(target=self._read, daemon=True).start()
        self.command(f'login nickname="{nickname}" username="{username}" password="{password}" clientname="e2e" protocol="5.14"')
        self.user_id = None
        # What the server sent at login: everyone logged in, and more.
        self.login_lines = self.drain()
        for line in self.login_lines:
            if line.startswith("accepted "):
                self.user_id = int(line.split("userid=")[1].split()[0])

    def _read(self):
        for raw in self.file:
            self.lines.put(raw.decode().rstrip("\r\n"))

    def send(self, line):
        self.sock.sendall((line + "\r\n").encode())

    def command(self, line):
        i = self.next_id
        self.next_id += 1
        self.send(f"{line} id={i}")
        end = time.time() + 5
        seen = []
        while time.time() < end:
            try:
                l = self.lines.get(timeout=0.5)
            except queue.Empty:
                continue
            seen.append(l)
            if l == f"end id={i}":
                errors = [x for x in seen if x.startswith("error ")]
                if errors:
                    raise AssertionError(f"{line} failed: {errors}")
                for x in seen:
                    self.lines.put(x)
                return
        raise AssertionError(f"no reply to {line}")

    def drain(self):
        out = []
        while True:
            try:
                out.append(self.lines.get_nowait())
            except queue.Empty:
                return out

    def wait_line(self, pred, what, timeout=10):
        end = time.time() + timeout
        while time.time() < end:
            try:
                l = self.lines.get(timeout=0.3)
            except queue.Empty:
                continue
            if pred(l):
                print("  ok:", what)
                return l
        raise AssertionError("timed out: " + what)

    def close(self):
        try:
            self.send("quit")
            self.sock.close()
        except OSError:
            pass


class FakeApns(http.server.BaseHTTPRequestHandler):
    """Stands in for Apple: POST /3/device/<token> with the payload."""
    pushes = queue.Queue()
    # Tokens of copies of the app that were "uninstalled".
    uninstalled = set()

    def do_POST(self):
        body = self.rfile.read(int(self.headers["Content-Length"]))
        token = self.path.rsplit("/", 1)[-1]
        if token in FakeApns.uninstalled:
            self.send_response(410)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"reason":"Unregistered"}')
            return
        FakeApns.pushes.put({
            "token": self.path.rsplit("/", 1)[-1],
            "topic": self.headers.get("apns-topic"),
            "type": self.headers.get("apns-push-type"),
            "auth": self.headers.get("authorization", ""),
            "payload": json.loads(body),
        })
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b'{"ok":true}')

    def log_message(self, *a):
        pass


def open_push(push, key):
    sealed = base64.b64decode(push["payload"]["ttng"]["sealed"])
    plain = ChaCha20Poly1305(key).decrypt(sealed[:12], sealed[12:], None)
    return json.loads(plain)


def next_push(key, pred, what, timeout=10):
    end = time.time() + timeout
    while time.time() < end:
        try:
            p = FakeApns.pushes.get(timeout=0.3)
        except queue.Empty:
            continue
        content = open_push(p, key)
        if pred(content):
            check(True, what)
            return p, content
    raise AssertionError("no push: " + what)


class Follower:
    """The app's live view: a WebSocket of events."""

    def __init__(self, token, since):
        self.events = queue.Queue()
        self.ws = ws_connect(f"ws://127.0.0.1:18650/v1/ws?since={since}", additional_headers={"Authorization": f"Bearer {token}"})
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        try:
            for msg in self.ws:
                self.events.put(json.loads(msg))
        except Exception:
            pass

    def wait(self, pred, what, timeout=10):
        end = time.time() + timeout
        while time.time() < end:
            try:
                m = self.events.get(timeout=0.3)
            except queue.Empty:
                continue
            if m.get("type") == "event" and pred(m["event"]["event"]):
                print("  ok:", what)
                return m["event"]
        raise AssertionError("timed out: " + what)

    def close(self):
        self.ws.close()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tt5srv", help="start this TeamTalk server for the test")
    ap.add_argument("--ngmon", default=os.path.join(HERE, "..", "target", "debug", "ngmon"))
    args = ap.parse_args()

    work = tempfile.mkdtemp(prefix="ngmon-e2e-")
    procs = []
    try:
        if args.tt5srv:
            srv = os.path.join(work, "srv")
            os.makedirs(os.path.join(srv, "files"))
            shutil.copy(os.path.join(HERE, "fixtures", "tt5srv.xml"), srv)
            procs.append(subprocess.Popen([args.tt5srv, "-nd", "-wd", srv], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
            wait_for(lambda: socket.socket().connect_ex(("127.0.0.1", TT_PORT)) == 0, "TeamTalk server up")

        apns = http.server.ThreadingHTTPServer(("127.0.0.1", APNS_PORT), FakeApns)
        threading.Thread(target=apns.serve_forever, daemon=True).start()

        key = os.path.join(work, "test.p8")
        subprocess.run(["openssl", "genpkey", "-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:P-256", "-out", key], check=True, capture_output=True)
        cfg = os.path.join(work, "ngmon.toml")
        with open(cfg, "w") as f:
            f.write('listen = "127.0.0.1:18650"\n'
                    # The test's TeamTalk server is on this machine.
                    'allow_private_hosts = true\n'
                    '[limits]\nservers_per_device = 2\n'
                    '[push]\nmode = "apns"\n'
                    f'[push.apns]\nkey_file = "{key}"\nkey_id = "TESTKEY123"\nteam_id = "5NJK4F832Z"\nendpoint = "http://127.0.0.1:{APNS_PORT}"\n')
        ngmon = [os.path.abspath(args.ngmon), "--config", cfg]

        print("Starting the monitor")
        log = open(os.path.join(work, "serve.log"), "w")
        procs.append(subprocess.Popen(ngmon + ["serve"], stderr=log, env={**os.environ, "NGMON_LOG": "ngmon=debug"}))
        wait_for(lambda: requests.get(API + "/v1/info").ok if _up() else False, "API up")

        print("Registering")
        check(requests.get(API + "/v1/servers").status_code == 401, "API refuses unregistered requests")
        r = requests.post(API + "/v1/register", json={"device_name": "Test iPhone"})
        check(r.ok, "app install registers itself")
        reg = r.json()
        H = {"Authorization": "Bearer " + reg["token"]}
        key = base64.b64decode(reg["push_key"])
        other = requests.post(API + "/v1/register", json={"device_name": "Someone else"}).json()
        H2 = {"Authorization": "Bearer " + other["token"]}
        check(requests.put(API + "/v1/me/push", headers=H, json={"apns_token": FAKE_APNS_TOKEN, "sandbox": True, "app_ref": "e2e-ref"}).status_code == 204, "push registered")

        print("Adding a server from the app")
        server = {"name": "Test", "host": "127.0.0.1", "tcp_port": TT_PORT, "nickname": "NGMon", "username": "monitor", "password": "monitor", "status_msg": "Watching", "status_mode": 256}
        r = requests.post(API + "/v1/servers", headers=H, json=server)
        check(r.status_code == 201, "server added")
        sid = r.json()["id"]
        r = requests.post(API + "/v1/servers", headers=H, json={**server, "host": "no-such-host.invalid"})
        check(r.status_code == 400 and "no-such-host.invalid" in r.json()["error"], "unknown host refused with a reason")
        requests.post(API + "/v1/servers", headers=H, json={**server, "name": "Second"})
        r = requests.post(API + "/v1/servers", headers=H, json={**server, "name": "Third"})
        check(r.status_code == 409 and "up to 2" in r.json()["error"], "per-install server limit")
        second = [x for x in requests.get(API + "/v1/servers", headers=H).json()["servers"] if x["name"] == "Second"][0]["id"]
        check(requests.delete(API + f"/v1/servers/{second}", headers=H).status_code == 204, "server removed")

        print("Keeping installs apart")
        check(requests.get(API + "/v1/servers", headers=H2).json()["servers"] == [], "another install sees no servers")
        check(requests.get(API + f"/v1/servers/{sid}", headers=H2).status_code == 404, "another install cannot open the server")
        check(requests.get(API + f"/v1/servers/{sid}/config", headers=H2).status_code == 404, "another install cannot read its settings")
        check(requests.post(API + f"/v1/servers/{sid}/messages", headers=H2, json={"to": "broadcast", "text": "x"}).status_code == 404, "another install cannot act on it")
        check(requests.delete(API + f"/v1/servers/{sid}", headers=H2).status_code == 404, "another install cannot remove it")
        cfgjson = requests.get(API + f"/v1/servers/{sid}/config", headers=H).json()
        check("password" not in cfgjson and cfgjson["username"] == "monitor", "settings come back without the password")

        print("Monitoring")
        wait_for(lambda: requests.get(API + "/v1/servers", headers=H).json()["servers"][0]["status"] == "logged_in", "monitor logged in")
        view = requests.get(API + f"/v1/servers/{sid}", headers=H).json()
        paths = sorted(c["path"] for c in view["state"]["channels"])
        check(paths == ["/", "/Lobby/"], "channels mirrored")
        check(view["server"]["server_name"] == "NG Monitor Test", "server name known")
        me = view["state"]["me"]["user_id"]
        mon = [u for u in view["state"]["users"] if u["id"] == me][0]
        check(mon["nickname"] == "NGMon" and mon["status_msg"] == "Watching", "monitor's own nickname and status")
        check(mon["status_mode"] & 256, "monitor logs in with its gender (female)")
        r = requests.post(API + f"/v1/servers/{sid}/actions", headers=H, json={"action": "status", "status_mode": 0, "status_msg": "Still watching"})
        check(r.status_code == 204, "status change accepted")

        def own():
            v = requests.get(API + f"/v1/servers/{sid}", headers=H).json()
            return [u for u in v["state"]["users"] if u["id"] == me][0]
        wait_for(lambda: own()["status_msg"] == "Still watching", "status message changed")
        check(own()["status_mode"] & 256, "status change keeps the monitor's gender")
        cfg = requests.get(API + f"/v1/servers/{sid}/config", headers=H).json()
        check(cfg["status_msg"] == "Still watching" and cfg["status_mode"] == 256, "status change saved in the settings")
        server["status_msg"] = "Still watching"
        changed = dict(server, status_mode=4096)
        check(requests.put(API + f"/v1/servers/{sid}", headers=H, json=changed).status_code == 204, "gender changed in the settings")
        wait_for(lambda: own()["status_mode"] & 4096, "new gender applied")
        check(own()["id"] == me and own()["status_msg"] == "Still watching", "applied without logging in again")
        r = requests.post(API + f"/v1/servers/{sid}/actions", headers=H, json={"action": "nickname", "nickname": "NGMon2"})
        check(r.status_code == 204, "nickname changed from the server screen")
        wait_for(lambda: own()["nickname"] == "NGMon2", "new nickname shown on the server")
        cfg = requests.get(API + f"/v1/servers/{sid}/config", headers=H).json()
        check(cfg["nickname"] == "NGMon2" and own()["id"] == me, "nickname saved, without logging in again")
        changed = dict(changed, nickname="NGMon3")
        check(requests.put(API + f"/v1/servers/{sid}", headers=H, json=changed).status_code == 204, "nickname changed in the settings")
        wait_for(lambda: own()["nickname"] == "NGMon3", "settings nickname applied")
        check(own()["id"] == me, "settings nickname applied without logging in again")
        changed = dict(changed, nickname="NGMon")
        requests.put(API + f"/v1/servers/{sid}", headers=H, json=changed)
        wait_for(lambda: own()["nickname"] == "NGMon", "nickname restored")
        live = Follower(reg["token"], view["seq"])
        other_live = Follower(other["token"], 0)

        alice = TTUser("Alice", "alice", "alice")
        live.wait(lambda e: e["type"] == "logged_in" and e["user"]["nickname"] == "Alice", "app sees Alice log in")
        next_push(key, lambda c: c["body"] == "Alice logged in", "push: Alice logged in")
        p = None

        alice.command("join chanid=2")
        live.wait(lambda e: e["type"] == "joined" and e["channel_path"] == "/Lobby/", "app sees Alice join /Lobby/")

        print("Private messages")
        long_text = "Hello monitor! " + "x" * 600 + " end"
        for i in range(0, len(long_text), 511):
            part = long_text[i:i + 511]
            more = 1 if i + 511 < len(long_text) else 0
            alice.command(f'message type=1 destuserid={me} content="{part}" more={more}')
        ev = live.wait(lambda e: e["type"] == "message", "app gets Alice's message")
        check(ev["event"]["message"]["text"] == long_text, "long message joined from its parts")
        p, c = next_push(key, lambda c: c["data"].get("event") == "private_message", "push: private message")
        check(p["token"] == FAKE_APNS_TOKEN and p["topic"] == "com.matthewdovi.TeamTalk-NG", "push addressed to the app on this phone")
        check(p["auth"].startswith("bearer ") or p["auth"].startswith("Bearer "), "push signed with the APNs key")
        check(p["payload"]["aps"]["category"] == "TTNG_PRIVATE_MESSAGE", "push has the reply category")
        check(p["payload"]["ttng"]["ref"] == "e2e-ref", "push names the install key that opens it")
        check("Hello monitor" not in json.dumps(p["payload"]), "push text sealed from Apple")
        check(c["title"] == "Alice" and c["data"]["user_id"] == alice.user_id and "conversation_id" in c["data"], "push opens Alice's conversation")
        conv = requests.get(API + "/v1/conversations", headers=H).json()["conversations"]
        check(conv[0]["user_id"] == alice.user_id and conv[0]["active"] and conv[0]["unread"] == 1, "conversation with Alice's user ID listed as unread")
        cid = conv[0]["id"]
        check(c["data"]["conversation_id"] == cid, "push names that conversation")

        reply = "Hi Alice, \"quoted\" and\nmultiline \\ ok"
        r = requests.post(API + f"/v1/servers/{sid}/messages", headers=H, json={"to": "user", "user_id": alice.user_id, "conversation_id": cid, "text": reply})
        check(r.status_code == 204, "reply sent from the app")
        got = alice.wait_line(lambda l: l.startswith("messagedeliver") and f"srcuserid={me}" in l, "Alice receives the reply")
        check('content="Hi Alice, \\"quoted\\" and\\nmultiline \\\\ ok"' in got, "reply text arrives intact")
        hist = requests.get(API + f"/v1/servers/{sid}/conversations/{cid}/messages", headers=H).json()
        msgs = hist["messages"]
        check(hist["seq"] >= ev["seq"], "history says how far it goes, so the app can skip events it already has")
        check([m["outgoing"] for m in msgs] == [False, True] and msgs[1]["text"] == reply, "history holds both messages")
        requests.post(API + f"/v1/servers/{sid}/conversations/{cid}/read", headers=H)
        check(requests.get(API + f"/v1/servers/{sid}/conversations/{cid}/messages", headers=H2).status_code == 404, "another install cannot read the conversation")
        check(requests.delete(API + f"/v1/servers/{sid}/conversations/{cid}", headers=H2).status_code == 404, "another install cannot delete it")
        check(requests.get(API + "/v1/conversations", headers=H).json()["conversations"][0]["unread"] == 0, "marked read")

        print("Channels and actions")
        r = requests.post(API + f"/v1/servers/{sid}/actions", headers=H, json={"action": "join", "channel": "/Lobby/"})
        check(r.status_code == 204, "monitor joins /Lobby/ from the app")
        live.wait(lambda e: e["type"] == "my_channel" and e.get("channel_id") == 2, "app sees the monitor in /Lobby/")
        alice.command('message type=2 chanid=2 content="hey ngmon, are you there?"')
        next_push(key, lambda c: c["data"].get("event") == "channel_message", "push: channel mention")
        alice.command('message type=2 chanid=2 content="just chatting"')
        r = requests.post(API + f"/v1/servers/{sid}/messages", headers=H, json={"to": "channel", "text": "Hello channel"})
        check(r.status_code == 204, "channel message from the app")
        alice.wait_line(lambda l: l.startswith("messagedeliver type=2") and "Hello channel" in l, "Alice hears the channel message")
        r = requests.post(API + f"/v1/servers/{sid}/actions", headers=H, json={"action": "move", "user_id": alice.user_id, "channel_id": 1})
        check(r.status_code == 422 and "error" in r.json(), "server's refusal (no move right) reaches the app")
        r = requests.post(API + f"/v1/servers/{sid}/messages", headers=H, json={"to": "user", "user_id": 9999, "text": "x"})
        check(r.status_code == 409, "messaging someone not logged in is refused")
        requests.put(API + "/v1/me/prefs", headers=H, json={"logouts": "none"})

        print("Resuming after missed events")
        last = live.wait(lambda e: e["type"] == "message" and e["message"]["text"] == "Hello channel", "app sees its own channel message")
        live.close()
        alice.command('changestatus statusmode=0 statusmsg="Away for lunch"')
        alice.close()
        time.sleep(1)
        live = Follower(reg["token"], last["seq"])
        live.wait(lambda e: e["type"] == "user_updated" and e["user"]["status_msg"] == "Away for lunch", "missed status change replayed")
        live.wait(lambda e: e["type"] == "logged_out" and e["user"]["username"] == "alice", "missed logout replayed")
        ended = [x for x in requests.get(API + "/v1/conversations", headers=H).json()["conversations"] if x["id"] == cid][0]
        check(not ended["active"], "Alice logging out ends her conversation, as in TeamTalk")
        r = requests.post(API + f"/v1/servers/{sid}/messages", headers=H, json={"to": "user", "user_id": alice.user_id, "conversation_id": cid, "text": "late"})
        check(r.status_code == 409 and "ended" in r.json()["error"], "replying to an ended conversation is refused")
        alice2 = TTUser("Alice", "alice", "alice")
        alice2.command(f'message type=1 destuserid={me} content="back again" more=0')
        def new_conversation():
            convs = [x for x in requests.get(API + "/v1/conversations", headers=H).json()["conversations"] if x["user_id"] == alice2.user_id and x["active"]]
            return convs[0] if convs else None
        fresh = wait_for(new_conversation, "her next login is a new conversation")
        check(fresh["id"] != cid and fresh["last_text"] == "back again", "the old conversation keeps its own history")
        r = requests.delete(API + f"/v1/servers/{sid}/conversations/{fresh['id']}", headers=H)
        check(r.status_code == 204, "a conversation is deleted")
        check(all(x["id"] != fresh["id"] for x in requests.get(API + "/v1/conversations", headers=H).json()["conversations"]), "it is gone from the list")
        check(requests.get(API + f"/v1/servers/{sid}/conversations/{fresh['id']}/messages", headers=H).status_code == 404, "its messages are gone")
        alice2.command(f'message type=1 destuserid={me} content="one more" more=0')
        again = wait_for(new_conversation, "writing again starts a new conversation")
        check(again["id"] != fresh["id"] and again["last_text"] == "one more", "with only the new message")
        alice2.close()
        check(all(open_push(p, key)["data"].get("event") != "logged_out" for p in list(FakeApns.pushes.queue)), "logout push skipped per prefs")

        print("Reconnecting")
        admin = TTUser("Admin", "admin", "admin")
        admin.command(f"kick userid={me}")
        live.wait(lambda e: e["type"] == "kicked", "app sees the monitor kicked")
        live.wait(lambda e: e["type"] == "connection" and e["status"] == "logged_in", "monitor logs back in by itself", timeout=20)
        admin.close()
        live.close()

        events = requests.get(API + "/v1/events?limit=5", headers=H).json()
        check(len(events["events"]) == 5 and events["events"][-1]["seq"] == events["last_seq"], "event history API")
        check(requests.get(API + "/v1/events", headers=H2).json()["events"] == [], "another install gets none of its events")
        check(all(m.get("type") != "event" for m in list(other_live.events.queue)), "another install's live view stays quiet")
        other_live.close()

        print("Sharing an account with the phone")
        r = requests.post(API + "/v1/servers", headers=H, json={**server, "name": "Solo", "username": "solo", "password": "solo"})
        solo_id = r.json()["id"]
        status = lambda: [x for x in requests.get(API + "/v1/servers", headers=H).json()["servers"] if x["id"] == solo_id][0]
        wait_for(lambda: status()["status"] == "logged_in", "monitor logged in with a one-login account")
        before = FakeApns.pushes.qsize()
        phone = TTUser("Phone", "solo", "solo")
        wait_for(lambda: status()["status"] == "stepped_aside", "monitor steps aside when the same account logs in")
        check("same account" in status()["reason"], "the app is told why")
        time.sleep(4)
        phone.send("ping id=99")
        phone.wait_line(lambda l: l == "pong", "the phone stays logged in")
        check(all(open_push(p, key)["data"].get("event") != "kicked" for p in list(FakeApns.pushes.queue)[before:]), "no push about being kicked")
        check(requests.post(API + f"/v1/servers/{solo_id}/pause", headers=H, json={"minutes": 30}).status_code == 204, "app pauses the server")
        wait_for(lambda: status()["status"] == "paused", "server shows as paused")
        check(requests.post(API + f"/v1/servers/{solo_id}/pause", headers=H2).status_code == 404, "another install cannot pause it")
        phone.close()
        check(requests.delete(API + f"/v1/servers/{solo_id}/pause", headers=H).status_code == 204, "app resumes the server")
        wait_for(lambda: status()["status"] == "logged_in", "monitor logs back in after resuming", timeout=20)

        print("Managing the server")
        r = requests.post(API + f"/v1/servers/{sid}/admin", headers=H, json={"command": "listaccounts", "params": {"index": 0, "count": 100}})
        check(r.status_code == 422, "a non-admin monitor gets the server's refusal")
        r = requests.post(API + "/v1/servers", headers=H2, json={**server, "name": "Admin", "nickname": "NG Admin", "username": "admin", "password": "admin"})
        aid = r.json()["id"]
        wait_for(lambda: requests.get(API + "/v1/servers", headers=H2).json()["servers"][0]["status"] == "logged_in", "admin monitor logged in")
        admin = lambda command, **params: requests.post(API + f"/v1/servers/{aid}/admin", headers=H2, json={"command": command, "params": params})
        accounts = admin("listaccounts", index=0, count=1000).json()["lines"]
        check({"monitor", "alice", "admin"} <= {a["username"] for a in accounts if a["type"] == "useraccount"}, "accounts listed")
        check(admin("newaccount", username="dave", password="pw", usertype=1, userrights=259591, note="from the app", initchan="/Lobby/").ok, "account created")
        dave = [a for a in admin("listaccounts", index=0, count=1000).json()["lines"] if a.get("username") == "dave"]
        check(dave and dave[0]["note"] == "from the app" and dave[0]["initchan"] == "/Lobby/", "new account has its settings")
        check(admin("delaccount", username="dave").ok, "account deleted")
        check(admin("ban", ipaddr="203.0.113.9").ok and admin("ban", username="troll", bantype=2).ok, "bans added")
        bans = admin("listbans", index=0, count=1000).json()["lines"]
        check({b.get("ipaddr") for b in bans} >= {"203.0.113.9"} and any(b.get("username") == "troll" for b in bans), "bans listed")
        check(admin("unban", ipaddr="203.0.113.9").ok and admin("unban", username="troll", bantype=2).ok, "bans removed")
        check(admin("listbans", index=0, count=1000).json()["lines"] == [], "ban list empty again")
        r = admin("updateserver", servername="Renamed by NG", motdraw="Hello %users%")
        check(r.ok and r.json()["lines"][0]["servername"] == "Renamed by NG", "server settings changed")
        props = requests.get(API + f"/v1/servers/{aid}", headers=H2).json()["state"]["info"]["properties"]
        check(props.get("motdraw") == "Hello %users%" and "voicetxlimit" in props, "full server settings in the snapshot")
        admin("updateserver", servername="NG Monitor Test", motdraw="Test server for ngmon")
        check("uptime" in admin("querystats").json()["lines"][0], "server statistics")
        check(admin("quit").status_code == 400, "commands outside server management refused")
        check(admin("delaccount", username="x", password="y").status_code == 400, "unexpected fields refused")
        requests.delete(API + f"/v1/servers/{aid}", headers=H2)

        print("Reinstalling and new iPhones")
        # A second iPhone with the same sign-up (from iCloud Keychain).
        second_phone = "cd" * 32
        r = requests.put(API + "/v1/me/push", headers=H, json={"apns_token": second_phone, "sandbox": True, "app_ref": "e2e-ref", "install_id": "second-phone"})
        check(r.status_code == 204, "a second iPhone registers for the same account")
        while not FakeApns.pushes.empty():
            FakeApns.pushes.get()
        bob = TTUser("Bob", "admin", "admin")
        got = set()
        end = time.time() + 10
        while len(got) < 2 and time.time() < end:
            try:
                p = FakeApns.pushes.get(timeout=0.5)
            except queue.Empty:
                continue
            if open_push(p, key)["data"].get("event") == "logged_in":
                got.add(p["token"])
        check(got == {FAKE_APNS_TOKEN, second_phone}, "both iPhones are notified")
        bob.close()
        # The first iPhone deletes the app; the daily silent check finds out.
        time.sleep(2)  # notifications about Bob still on their way
        FakeApns.uninstalled.add(FAKE_APNS_TOKEN)
        while not FakeApns.pushes.empty():
            FakeApns.pushes.get()
        out = subprocess.run(ngmon + ["check-phones"], capture_output=True, text=True).stdout
        check(out.strip() == "2 phones checked, 1 no longer have the app", "the silent check finds the deleted app")
        silent = [p for p in list(FakeApns.pushes.queue) if p["token"] == second_phone and p["type"] == "background"]
        check(silent and silent[-1]["payload"] == {"aps": {"content-available": 1}}, "the check shows nothing on the phone")
        check("1 phones" in subprocess.run(ngmon + ["device", "list"], capture_output=True, text=True).stdout.splitlines()[0], "the deleted copy stops getting pushes")
        # The second iPhone deletes it too, and nothing is heard for two days.
        FakeApns.uninstalled.add(second_phone)
        subprocess.run(ngmon + ["check-phones"], capture_output=True, text=True)
        import sqlite3
        db = sqlite3.connect(os.path.join(work, "data", "ngmon.sqlite"))
        db.execute("UPDATE devices SET last_seen = ? WHERE id = ?", (int((time.time() - 2 * 86400) * 1000), reg["device_id"]))
        db.commit()
        db.close()
        out = subprocess.run(ngmon + ["sweep"], capture_output=True, text=True).stdout
        check("1 put to sleep" in out, "a day after the app is gone from every iPhone, the account sleeps")
        wait_for(lambda: "asleep" in subprocess.run(ngmon + ["device", "list"], capture_output=True, text=True).stdout.splitlines()[0], "account shown asleep")
        time.sleep(4)
        alice3 = TTUser("Alice", "alice", "alice")
        check(not any(l.startswith("loggedin") and 'nickname="NGMon"' in l for l in alice3.login_lines), "while asleep, its monitors are logged out of the server")
        alice3.close()
        # The app comes back (reinstalled, signed in from iCloud Keychain): it wakes up.
        requests.get(API + "/v1/servers", headers=H)
        check(not any("asleep" in l for l in subprocess.run(ngmon + ["device", "list"], capture_output=True, text=True).stdout.splitlines()[:1]), "any contact from the app wakes the account")
        wait_for(lambda: requests.get(API + "/v1/servers", headers=H).json()["servers"][0]["status"] == "logged_in", "its monitor logs back in", timeout=20)

        print("New iPhone before iCloud Keychain catches up")
        late = requests.post(API + "/v1/register", json={"device_name": "New iPhone"}).json()
        HL = {"Authorization": "Bearer " + late["token"]}
        r = requests.post(API + "/v1/servers", headers=HL, json={**server, "name": "Added on the new iPhone", "nickname": "NGNew"})
        late_server = r.json()["id"]
        requests.put(API + "/v1/me/push", headers=HL, json={"apns_token": "ef" * 32, "sandbox": True, "app_ref": "late-ref", "install_id": "new-iphone"})
        check(requests.post(API + "/v1/me/merge", headers=H, json={"token": "not-a-token"}).status_code == 404, "merging needs the other sign-up's real token")
        check(requests.post(API + "/v1/me/merge", headers=H, json={"token": late["token"]}).status_code == 204, "the app merges the newer sign-up into the older")
        mine = {x["id"]: x for x in requests.get(API + "/v1/servers", headers=H).json()["servers"]}
        check(late_server in mine, "the server added on the new iPhone is now on the original sign-up")
        check(requests.get(API + "/v1/servers", headers=HL).status_code == 401, "the newer sign-up is gone")
        wait_for(lambda: requests.get(API + f"/v1/servers/{late_server}", headers=H).json()["server"]["status"] == "logged_in", "its monitor keeps running", timeout=20)
        # (Both earlier test phones deleted the app above, so only the new one is left.)
        check("1 phones" in subprocess.run(ngmon + ["device", "list"], capture_output=True, text=True).stdout.splitlines()[0], "the new iPhone's notifications moved over too")
        requests.delete(API + f"/v1/servers/{late_server}", headers=H)

        print("Leaving")
        check(requests.delete(API + "/v1/me", headers=H).status_code == 204, "install forgets itself")
        check(requests.get(API + "/v1/servers", headers=H).status_code == 401, "its token no longer works")
        wait_for(lambda: "monitor" not in subprocess.run(ngmon + ["servers"], capture_output=True, text=True).stdout, "its servers are gone")
        print("\nAll end-to-end checks passed.")
    except Exception:
        log_path = os.path.join(work, "serve.log")
        if os.path.exists(log_path):
            print("\n--- ngmon log ---\n" + open(log_path).read()[-6000:])
        raise
    finally:
        for p in reversed(procs):
            p.terminate()
            try:
                p.wait(5)
            except subprocess.TimeoutExpired:
                p.kill()
        shutil.rmtree(work, ignore_errors=True)


def _up():
    s = socket.socket()
    try:
        return s.connect_ex(("127.0.0.1", 18650)) == 0
    finally:
        s.close()


if __name__ == "__main__":
    main()

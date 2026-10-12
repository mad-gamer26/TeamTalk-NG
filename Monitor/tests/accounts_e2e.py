#!/usr/bin/env python3
"""End-to-end test of NG Account: accounts, sync and sound packs.

Runs `ngmon serve` with email written to a folder (so the test reads the
codes) and a stand-in for Apple's push service, then uses the API and
WebSocket as two TeamTalk NG installs would. No TeamTalk server needed.

    cargo build
    python3 tests/accounts_e2e.py

Needs: requests, websockets.
"""

import argparse
import glob
import http.server
import json
import os
import queue
import shutil
import subprocess
import tempfile
import threading
import time
import zipfile

import requests
from websockets.sync.client import connect as ws_connect

HERE = os.path.dirname(os.path.abspath(__file__))
PORT = 18660
API = f"http://127.0.0.1:{PORT}"
APNS_PORT = 18661
WAV = b"RIFF\x24\x00\x00\x00WAVEfmt " + b"\x10\x00\x00\x00\x01\x00\x01\x00\x44\xac\x00\x00\x88\x58\x01\x00\x02\x00\x10\x00data\x00\x00\x00\x00"


def check(cond, what):
    if not cond:
        raise AssertionError(what)
    print("  ok:", what)


def wait_for(fn, what, timeout=10.0):
    end = time.time() + timeout
    while time.time() < end:
        v = fn()
        if v:
            print("  ok:", what)
            return v
        time.sleep(0.1)
    raise AssertionError("timed out: " + what)


class FakeApns(http.server.BaseHTTPRequestHandler):
    pushes = queue.Queue()

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("content-length", 0)))
        FakeApns.pushes.put({"token": self.path.rsplit("/", 1)[-1], "body": json.loads(body)})
        self.send_response(200)
        self.end_headers()

    def log_message(self, *a):
        pass


class Outbox:
    def __init__(self, path):
        self.path = path
        self.seen = set()

    def code(self, to, purpose):
        """The newest code emailed to `to` for `purpose`."""
        def find():
            for f in sorted(glob.glob(os.path.join(self.path, "*.json"))):
                if f in self.seen:
                    continue
                m = json.load(open(f))
                if m["to"] == to and m["purpose"] == purpose:
                    self.seen.add(f)
                    return m
            return None
        m = wait_for(find, f"{purpose} code emailed to {to}")
        assert m["code"] in m["body"] and len(m["code"]) == 6
        return m["code"]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ngmon", default=os.path.join(HERE, "..", "target", "debug", "ngmon"))
    args = ap.parse_args()
    work = tempfile.mkdtemp(prefix="ngmon-accounts-")
    proc = None
    try:
        apns = http.server.ThreadingHTTPServer(("127.0.0.1", APNS_PORT), FakeApns)
        threading.Thread(target=apns.serve_forever, daemon=True).start()
        key = os.path.join(work, "test.p8")
        subprocess.run(["openssl", "genpkey", "-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:P-256", "-out", key], check=True, capture_output=True)
        outbox = os.path.join(work, "outbox")
        cfg = os.path.join(work, "ngmon.toml")
        with open(cfg, "w") as f:
            f.write(f'listen = "127.0.0.1:{PORT}"\nallow_private_hosts = true\n'
                    '[push]\nmode = "apns"\n'
                    f'[push.apns]\nkey_file = "{key}"\nkey_id = "TESTKEY123"\nteam_id = "5NJK4F832Z"\nendpoint = "http://127.0.0.1:{APNS_PORT}"\n'
                    f'[mail]\nmode = "outbox"\noutbox = "{outbox}"\nfrom = "TeamTalk NG <no-reply@example.com>"\n')
        ngmon = [os.path.abspath(args.ngmon), "--config", cfg]
        log = open(os.path.join(work, "serve.log"), "w")
        proc = subprocess.Popen(ngmon + ["serve"], stderr=log)
        wait_for(lambda: _get("/v1/info"), "API up")
        mail = Outbox(outbox)

        def install(name):
            return {"install_id": name, "device_name": name}

        print("Signing up")
        email = "Matt@Example.com"
        check(requests.post(API + "/v1/account/signup", json={"email": email, "password": "short"}).status_code == 400, "short passwords refused")
        check(requests.post(API + "/v1/account/signup", json={"email": "not an email", "password": "long enough pw"}).status_code == 400, "bad emails refused")
        # An install from before NG Account, with a monitor.
        old = requests.post(API + "/v1/register", json={"device_name": "Old iPhone"}).json()
        HO = {"Authorization": "Bearer " + old["token"]}
        r = requests.post(API + "/v1/servers", headers=HO, json={"name": "Home", "host": "127.0.0.1", "tcp_port": 1, "nickname": "Mon", "username": "u", "password": "p"})
        check(r.status_code == 201, "the old install monitors a server")
        check(requests.post(API + "/v1/account/signup", json={"email": email, "password": "correct horse"}).status_code == 202, "sign-up starts")
        code = mail.code("matt@example.com", "signup")
        wrong = "000000" if code != "000000" else "111111"
        r = requests.post(API + "/v1/account/verify", json={"email": email, "code": wrong, **install("phone-a")})
        check(r.status_code == 401, "a wrong code is refused")
        r = requests.post(API + "/v1/account/verify", json={"email": email, "code": code, **install("phone-a"), "claim_token": old["token"]})
        check(r.ok, "the right code finishes the account")
        a = r.json()
        check(a["account"]["email"] == "matt@example.com" and "password_hash" not in a["account"], "account shown without its password")
        check(a["push_key"] == old["push_key"], "the old sign-up became the account's (same notification key)")
        HA = {"Authorization": "Bearer " + a["token"]}
        check([s["name"] for s in requests.get(API + "/v1/servers", headers=HA).json()["servers"]] == ["Home"], "the old install's monitor is the account's")
        check(requests.post(API + "/v1/account/verify", json={"email": email, "code": code, **install("phone-a")}).status_code == 401, "a used code can't be used again")
        check(requests.post(API + "/v1/account/signup", json={"email": email, "password": "another one"}).status_code == 409, "one account per email")
        check(requests.get(API + "/v1/account", headers=HO).status_code == 401, "an old sign-up token is not an account session")

        print("Signing in on a second phone")
        r = requests.post(API + "/v1/account/signin", json={"email": email, "password": "wrong password", **install("phone-b")})
        check(r.status_code == 401, "a wrong password is refused")
        other = requests.post(API + "/v1/register", json={"device_name": "Phone B before"}).json()
        requests.post(API + "/v1/servers", headers={"Authorization": "Bearer " + other["token"]},
                      json={"name": "Work", "host": "127.0.0.1", "tcp_port": 2, "nickname": "Mon", "username": "u", "password": "p"})
        r = requests.post(API + "/v1/account/signin", json={"email": "MATT@example.com ", "password": "correct horse", **install("phone-b"), "claim_token": other["token"]})
        check(r.ok, "signing in works, whatever the email's case")
        b = r.json()
        HB = {"Authorization": "Bearer " + b["token"]}
        check(b["push_key"] == a["push_key"], "every install gets the account's notification key")
        names = sorted(s["name"] for s in requests.get(API + "/v1/servers", headers=HB).json()["servers"])
        check(names == ["Home", "Work"], "phone B's old monitors merged into the account")
        sessions = requests.get(API + "/v1/account/sessions", headers=HA).json()["sessions"]
        check(sorted(s["install_id"] for s in sessions) == ["phone-a", "phone-b"], "both phones listed")
        check([s["current"] for s in sessions if s["install_id"] == "phone-a"] == [True], "the current phone is marked")

        print("Syncing")
        requests.put(API + "/v1/me/push", headers=HB, json={"apns_token": "bb" * 32, "sandbox": True, "app_ref": "r", "install_id": "phone-b"})
        requests.put(API + "/v1/me/push", headers=HA, json={"apns_token": "aa" * 32, "sandbox": True, "app_ref": "r", "install_id": "phone-a"})
        ws = ws_connect(API.replace("http", "ws") + "/v1/ws", additional_headers=HB)
        wait_for(lambda: json.loads(ws.recv())["type"] == "ready", "phone B is following live")
        while not FakeApns.pushes.empty():
            FakeApns.pushes.get()
        changes = [
            {"kind": "setting", "key": "nickname_preference", "base_rev": 0, "data": "Matt"},
            {"kind": "server", "key": "srv-1", "base_rev": 0, "data": {"name": "Home", "ipaddr": "tt.example.com", "password": "secret", "chanpasswd": ""}},
        ]
        r = requests.post(API + "/v1/sync", headers=HA, json={"changes": changes}).json()
        check(r["rev"] == 2 and len(r["applied"]) == 2 and not r["conflicts"], "phone A's changes applied")
        msg = json.loads(ws.recv(timeout=5))
        check(msg == {"type": "sync", "rev": 2}, "phone B hears about it live")
        push = FakeApns.pushes.get(timeout=5)
        check(push["token"] == "bb" * 32 and push["body"]["ttng"]["sync"] == 2, "and gets a silent push; phone A doesn't")
        check(FakeApns.pushes.empty(), "no push to the phone that made the change")
        pulled = requests.get(API + "/v1/sync?since=0", headers=HB).json()
        server = [x for x in pulled["records"] if x["key"] == "srv-1"][0]
        check(server["data"]["password"] == "secret", "phone B gets the server with its password")
        r = requests.post(API + "/v1/sync", headers=HB, json={"changes": [{"kind": "setting", "key": "nickname_preference", "base_rev": 0, "data": "Other"}]}).json()
        check(not r["applied"] and r["conflicts"][0]["data"] == "Matt", "a change from an old revision is a conflict")
        r = requests.post(API + "/v1/sync", headers=HB, json={"changes": [{"kind": "server", "key": "srv-1", "base_rev": server["rev"], "deleted": True}]}).json()
        check(r["applied"][0]["deleted"], "phone B deletes the server")
        since = requests.get(API + "/v1/sync?since=2", headers=HA).json()["records"]
        check([(x["key"], x["deleted"]) for x in since] == [("srv-1", True)], "phone A sees the delete")
        check(requests.get(API + "/v1/sync?since=0", headers=HA).json()["records"][0]["key"] == "nickname_preference", "from the start, deleted servers are left out")
        check(requests.get(API + "/v1/sync?since=99", headers=HA).json()["reset"], "a revision from the future starts over")
        ws.close()

        print("Sound packs")
        p = requests.post(API + "/v1/packs", headers=HA, json={"local_id": "local-pack-1", "name": "My Sounds"}).json()
        check(requests.post(API + "/v1/packs", headers=HB, json={"local_id": "local-pack-1", "name": "My Sounds"}).json()["id"] == p["id"],
              "the same app pack backs up once")
        r = requests.put(API + f"/v1/packs/{p['id']}/files/logged_on.wav", headers=HA, data=WAV)
        check(r.ok and r.json()["files"][0]["name"] == "logged_on.wav", "a sound is backed up")
        big_ok = WAV + bytes(2 * 1024 * 1024)
        r = requests.put(API + f"/v1/packs/{p['id']}/files/user_msg.wav", headers=HA, data=big_ok)
        check(r.ok and [f["size"] for f in r.json()["files"] if f["name"] == "user_msg.wav"] == [len(big_ok)], "a 2 MB sound uploads whole")
        requests.delete(API + f"/v1/packs/{p['id']}/files/user_msg.wav", headers=HA)
        check(requests.put(API + f"/v1/packs/{p['id']}/files/logged_on.wav", headers=HA, data=b"<html>not audio").status_code == 400, "files that aren't audio are refused")
        check(requests.put(API + f"/v1/packs/{p['id']}/files/evil.sh", headers=HA, data=WAV).status_code == 400, "only known sounds")
        big = b"RIFF\x00\x00\x00\x00WAVE" + bytes(26 * 1024 * 1024)
        check(requests.put(API + f"/v1/packs/{p['id']}/files/logged_off.wav", headers=HA, data=big).status_code in (409, 413), "over 25 MB is refused")
        check(requests.get(API + f"/v1/packs/{p['id']}/files/logged_on.wav", headers=HA).content == WAV, "the owner downloads it")
        check(requests.get(API + f"/v1/packs/{p['id']}/files/logged_on.wav").status_code == 404, "nobody else can, while it's private")
        check(requests.get(API + f"/v1/packs/{p['id']}/pack.zip", headers=HB).ok, "the owner's other phone gets the pack as a zip, to restore it")
        check(requests.get(API + f"/v1/packs/{p['id']}/pack.zip").status_code == 404, "nobody else does")
        check(requests.patch(API + f"/v1/packs/{p['id']}", headers=HA, json={"public": True}).status_code == 400, "publishing needs an author name")
        r = requests.patch(API + f"/v1/packs/{p['id']}", headers=HA, json={"public": True, "author": "Matt", "description": "Beeps"})
        check(r.ok and r.json()["public"], "published under a chosen name")
        cat = requests.get(API + "/v1/catalog?q=beeps").json()["packs"]
        check([c["name"] for c in cat] == ["My Sounds"] and "owner" not in cat[0] and cat[0]["author"] == "Matt", "it's in the catalog, without its owner")
        check(requests.get(API + f"/v1/packs/{p['id']}/files/logged_on.wav").content == WAV, "anyone can download it now")
        zr = requests.get(API + cat[0]["download_path"])
        import io
        zf = zipfile.ZipFile(io.BytesIO(zr.content))
        check(zr.ok and zf.namelist() == ["logged_on.wav"] and zf.read("logged_on.wav") == WAV, "the whole pack downloads as a zip")
        requests.post(API + f"/v1/catalog/{p['id']}/installed")
        requests.post(API + f"/v1/catalog/{p['id']}/installed")
        check(requests.get(API + "/v1/catalog").json()["packs"][0]["installs"] == 1, "installs counted once per address")
        check(requests.post(API + f"/v1/catalog/{p['id']}/report", json={"reason": "x"}).status_code == 401, "reporting needs an account")
        check(requests.post(API + f"/v1/catalog/{p['id']}/report", headers=HB, json={"reason": "test"}).status_code == 204, "reported")
        private = requests.post(API + "/v1/packs", headers=HA, json={"local_id": "local-pack-2", "name": "Private"}).json()
        requests.put(API + f"/v1/packs/{private['id']}/files/user_msg.wav", headers=HA, data=WAV + b"x")

        print("Official packs")
        z = os.path.join(work, "apple.zip")
        with zipfile.ZipFile(z, "w") as zf:
            zf.writestr("apple/logged_on.wav", WAV)
            zf.writestr("apple/readme.txt", "not a sound")
            zf.writestr("__MACOSX/._logged_on.wav", "junk")
        out = subprocess.run(ngmon + ["pack", "import-official", "apple", "Apple", "Matthew", "2", z], capture_output=True, text=True)
        check(out.returncode == 0, "imported: " + out.stdout.strip())
        cat = requests.get(API + "/v1/catalog").json()["packs"]
        check(cat[0]["id"] == "apple" and cat[0]["official"] and cat[0]["version"] == "2" and len(cat[0]["files"]) == 1, "Official packs come first, with their old IDs")
        out = subprocess.run(ngmon + ["pack", "assign", "apple", "MATT@example.com"], capture_output=True, text=True)
        check(out.returncode == 0 and "belongs to matt@example.com" in out.stdout, "an administrator assigns an Official pack: " + out.stdout.strip())
        mine = requests.get(API + "/v1/packs", headers=HA).json()["packs"]
        check("apple" in [x["id"] for x in mine] and [x for x in mine if x["id"] == "apple"][0]["official"], "it's in the account's packs, still Official")
        check(subprocess.run(ngmon + ["pack", "assign", "apple", "nobody@example.com"], capture_output=True).returncode != 0, "only to an account that exists")
        out = subprocess.run(ngmon + ["pack", "hide", p["id"]], capture_output=True, text=True)
        check(p["id"] not in [c["id"] for c in requests.get(API + "/v1/catalog").json()["packs"]], "an administrator can hide a pack")
        subprocess.run(ngmon + ["pack", "show", p["id"]], check=True)

        print("Passwords")
        check(requests.post(API + "/v1/account/password", headers=HA, json={"current": "nope", "new": "brand new pw"}).status_code == 401, "changing needs the current password")
        check(requests.post(API + "/v1/account/password", headers=HA, json={"current": "correct horse", "new": "brand new pw"}).status_code == 204, "password changed")
        check(requests.get(API + "/v1/account", headers=HB).status_code == 401, "other phones are signed out")
        check(requests.get(API + "/v1/account", headers=HA).ok, "this phone stays signed in")
        check(requests.post(API + "/v1/account/forgot", json={"email": "nobody@example.com"}).status_code == 202, "forgetting an unknown email looks the same")
        check(requests.post(API + "/v1/account/forgot", json={"email": email}).status_code == 202, "reset asked for")
        code = mail.code("matt@example.com", "reset")
        r = requests.post(API + "/v1/account/reset", json={"email": email, "code": code, "password": "after reset pw", **install("phone-b")})
        check(r.ok, "new password set with the code")
        HB = {"Authorization": "Bearer " + r.json()["token"]}
        check(requests.get(API + "/v1/account", headers=HA).status_code == 401, "a reset signs out everywhere else")
        r = requests.post(API + "/v1/account/signin", json={"email": email, "password": "after reset pw", **install("phone-a")})
        check(r.ok, "the new password works")
        HA = {"Authorization": "Bearer " + r.json()["token"]}

        print("Devices and sign-out")
        sid_b = [s["id"] for s in requests.get(API + "/v1/account/sessions", headers=HA).json()["sessions"] if s["install_id"] == "phone-b"][0]
        requests.put(API + "/v1/me/push", headers=HB, json={"apns_token": "bb" * 32, "sandbox": True, "app_ref": "r", "install_id": "phone-b"})
        check(requests.delete(API + f"/v1/account/sessions/{sid_b}", headers=HA).status_code == 204, "phone A signs phone B out")
        check(requests.get(API + "/v1/servers", headers=HB).status_code == 401, "phone B is signed out")
        out = subprocess.run(ngmon + ["account", "list"], capture_output=True, text=True).stdout
        check("matt@example.com, 1 devices signed in, 2 monitored servers" in out, "the command line lists accounts: " + out.strip())

        print("Stopping all monitors")
        extra = requests.post(API + "/v1/servers", headers=HA, json={"name": "Extra", "host": "127.0.0.1", "tcp_port": 3, "nickname": "Mon", "username": "u", "password": "p"})
        check(extra.status_code == 201, "a third monitor")
        check(requests.delete(API + "/v1/me", headers=HA).status_code == 204, "stop monitoring everything")
        check(requests.get(API + "/v1/servers", headers=HA).json()["servers"] == [], "every monitor stopped")
        check(requests.get(API + "/v1/account", headers=HA).ok, "the account is still fine")
        r = requests.post(API + "/v1/servers", headers=HA, json={"name": "Home", "host": "127.0.0.1", "tcp_port": 1, "nickname": "Mon", "username": "u", "password": "p"})
        r2 = requests.post(API + "/v1/servers", headers=HA, json={"name": "Work", "host": "127.0.0.1", "tcp_port": 2, "nickname": "Mon", "username": "u", "password": "p"})
        check(r.status_code == 201 and r2.status_code == 201, "and can monitor again")

        print("Export")
        ex = requests.get(API + "/v1/account/export", headers=HA)
        body = ex.json()
        check(ex.ok and body["account"]["email"] == "matt@example.com" and len(body["monitored_servers"]) == 2, "everything exported")
        check("secret" not in ex.text and "correct horse" not in ex.text and '"password": "p"' not in ex.text, "without passwords")

        print("Too many tries")
        for _ in range(10):
            requests.post(API + "/v1/account/signin", json={"email": email, "password": "wrong!", **install("x")})
        r = requests.post(API + "/v1/account/signin", json={"email": email, "password": "after reset pw", **install("x")})
        check(r.status_code == 429, "ten wrong passwords lock the account for a while")
        codes = [requests.post(API + "/v1/account/signup", json={"email": "spam@example.com", "password": "long enough"}).status_code for _ in range(6)]
        check(codes[:5] == [202] * 5 and codes[5] == 429, "codes to one address are limited")

        print("Deleting the account")
        check(requests.post(API + "/v1/account/delete", headers=HA, json={"password": "wrong"}).status_code == 401, "deleting needs the password")
        check(requests.post(API + "/v1/account/delete", headers=HA, json={"password": "after reset pw"}).status_code == 204, "account deleted")
        check(requests.get(API + "/v1/servers", headers=HA).status_code == 401, "its session is gone")
        check(requests.get(API + "/v1/servers", headers=HO).status_code == 401, "and the old sign-up with it")
        check(requests.get(API + f"/v1/packs/{private['id']}/files/user_msg.wav").status_code == 404, "its private packs are gone")
        check(p["id"] in [c["id"] for c in requests.get(API + "/v1/catalog").json()["packs"]], "its public pack stays in the catalog")
        check(requests.get(API + f"/v1/packs/{p['id']}/files/logged_on.wav").content == WAV, "and still downloads")
        check(requests.post(API + "/v1/account/signin", json={"email": email, "password": "after reset pw", **install("phone-a")}).status_code == 401, "the email can't sign in")
        out = subprocess.run(ngmon + ["servers"], capture_output=True, text=True).stdout
        check("Home" not in out and "Work" not in out, "its monitors stopped")
        print("\nAll NG Account checks passed.")
    except Exception:
        if proc:
            print("--- ngmon log ---")
            print(open(os.path.join(work, "serve.log")).read()[-4000:])
        raise
    finally:
        if proc:
            proc.terminate()
            proc.wait()
        shutil.rmtree(work, ignore_errors=True)


def _get(path):
    try:
        return requests.get(API + path, timeout=1).ok
    except requests.RequestException:
        return False


if __name__ == "__main__":
    main()

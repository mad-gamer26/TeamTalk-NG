#!/usr/bin/env python3
"""Checks TeamTalk NG's own monitor code (Client/iTeamTalk/iTeamTalk/Monitor)
against a live ngmon and a real TeamTalk server.

    tests/app_check/build.sh && python3 tests/app_check/drive.py /path/to/tt5srv

The app's monitor files are compiled for Mac Catalyst into a small program
(main.swift) that this script drives line by line while it plays TeamTalk
users. The TeamTalk SDK has no simulator build, so this is how the app's
networking, decoding and push opening are tested off the phone.
"""
import glob
import json, os, queue, shutil, subprocess, sys, tempfile, threading, time, http.server, socket
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))
import e2e
from e2e import TTUser, FakeApns, wait_for, check

HARNESS = os.path.join(HERE, "build", "harness")
TT5SRV = sys.argv[1]
NGMON = os.path.join(HERE, "..", "..", "target", "debug", "ngmon")
work = tempfile.mkdtemp(prefix="ngmon-app-")
procs = []
try:
    srv = os.path.join(work, "srv"); os.makedirs(os.path.join(srv, "files"))
    shutil.copy(os.path.join(HERE, "..", "fixtures", "tt5srv.xml"), srv)
    procs.append(subprocess.Popen([TT5SRV, "-nd", "-wd", srv], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
    wait_for(lambda: socket.socket().connect_ex(("127.0.0.1", 20333)) == 0, "TeamTalk server up")
    apns = http.server.ThreadingHTTPServer(("127.0.0.1", 18651), FakeApns)
    threading.Thread(target=apns.serve_forever, daemon=True).start()
    key = os.path.join(work, "test.p8")
    subprocess.run(["openssl", "genpkey", "-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:P-256", "-out", key], check=True, capture_output=True)
    cfg = os.path.join(work, "ngmon.toml")
    outbox = os.path.join(work, "outbox")
    open(cfg, "w").write('listen = "127.0.0.1:18650"\nallow_private_hosts = true\n[push]\nmode = "apns"\n'
                         f'[push.apns]\nkey_file = "{key}"\nkey_id = "TESTKEY123"\nteam_id = "5NJK4F832Z"\nendpoint = "http://127.0.0.1:18651"\n'
                         f'[mail]\nmode = "outbox"\noutbox = "{outbox}"\n')
    ng = [NGMON, "--config", cfg]
    procs.append(subprocess.Popen(ng + ["serve"], stderr=open(os.path.join(work, "serve.log"), "w")))
    wait_for(lambda: socket.socket().connect_ex(("127.0.0.1", 18650)) == 0, "monitor up")

    app = subprocess.Popen([HARNESS, "http://127.0.0.1:18650"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1)
    procs.append(app)
    lines = queue.Queue()
    threading.Thread(target=lambda: [lines.put(l.rstrip()) for l in app.stdout], daemon=True).start()

    def expect(prefix, timeout=20):
        end = time.time() + timeout
        while time.time() < end:
            try:
                l = lines.get(timeout=0.5)
            except queue.Empty:
                continue
            print("  app:", l)
            if l.startswith("FAIL"):
                raise AssertionError(l)
            if l.startswith(prefix):
                return l
        raise AssertionError("app never said " + prefix)

    def tell(cmd):
        app.stdin.write(cmd + "\n"); app.stdin.flush()

    me = int(expect("ok monitor user").split()[-1])
    expect("READY")
    alice = TTUser("Alice", "alice", "alice")
    tell("wait Alice logged in"); expect("ok got")
    alice.command("join chanid=2")
    tell("wait Alice joined /Lobby/"); expect("ok got")
    tell("model"); l = expect("ok model")
    check("Alice@/Lobby/" in l, "app's model places Alice in /Lobby/")
    tell("relogin"); l = expect("ok reloaded")
    check("/Lobby/" in l and "Alice" in l, "people and channels come back after the monitor logs in again")
    me = int(l.split("me=")[1].split()[0])
    # Alice messages the monitor.
    alice.drain()
    alice.command('message type=1 destuserid=%d content="Are you there?" more=0' % me)
    tell("wait Private message from Alice"); expect("ok got")
    tell("reply Yes, from the app!"); l = expect("ok replied")
    check(f'"{alice.user_id}:1:true"' in l, "conversation with Alice's user ID listed with the new message unread")
    check("<Are you there?" in l and ">Yes, from the app!" in l, "history in the app has both messages")
    alice.wait_line(lambda x: x.startswith("messagedeliver") and "Yes, from the app!" in x, "Alice gets the app's reply")
    tell("join 2"); expect("ok joined")
    alice.wait_line(lambda x: "hello from the app" in x, "Alice hears the app's channel message")
    tell("refused"); expect("ok refusal")
    # A push the monitor sent for the private message.
    push = None
    while not FakeApns.pushes.empty():
        p = FakeApns.pushes.get()
        if p["payload"]["aps"]["category"] == "TTNG_PRIVATE_MESSAGE":
            push = p
    check(push is not None, "monitor pushed the private message")
    tell("open " + json.dumps(push["payload"])); l = expect("ok opened")
    check(f"Alice | Are you there? | user={alice.user_id} server=1" in l, "app opens the sealed push")
    alice.close()
    tell("wait Alice logged out"); expect("ok got")
    alice4 = TTUser("Alice", "alice", "alice")
    tell("wait Alice logged in"); expect("ok got")
    tell("away"); expect("ok away")
    alice4.command('message type=1 destuserid=%d content="While you were away" more=0' % me)
    time.sleep(1)
    tell("back While you were away"); expect("ok caught up once")
    check(True, "a PM missed while away comes once, with no sound or speech")
    alice4.close()
    tell("merge"); l = expect("ok merged")
    check("Late" in l, "the app merges a second sign-up into the first")
    tell("unpair"); expect("ok stopped monitoring everything")
    check("Test" not in subprocess.run(ng + ["servers"], capture_output=True, text=True).stdout, "the service forgot the server")
    tell("account"); expect("ok refused")
    expect("CODE?")
    mail = json.load(open(glob.glob(os.path.join(outbox, "*.json"))[0]))
    tell("code " + mail["code"])
    expect("ok signed up with the code")
    expect("ok sync")
    expect("ok sound packs")
    expect("ok devices, export, sign-out")
    check(True, "the app's NG Account client works against the service")
    tell("quit"); expect("DONE")
    print("\nApp code checks passed.")
finally:
    for p in reversed(procs):
        p.terminate()
        try: p.wait(5)
        except subprocess.TimeoutExpired: p.kill()
    shutil.rmtree(work, ignore_errors=True)

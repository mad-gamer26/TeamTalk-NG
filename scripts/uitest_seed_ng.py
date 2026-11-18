"""For scripts/test-ios-ui.sh: an NG Account on the private NG service
(accounts are for publishing sound packs now).
    uitest_seed_ng.py URL EMAIL PASSWORD OUTBOX TOKEN_FILE"""
import json, os, sys, time, urllib.request

url, email, password, outbox, token_file = sys.argv[1:]


def call(method, path, body=None, token=None):
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = "Bearer " + token
    req = urllib.request.Request(url + path, method=method, headers=headers,
                                 data=json.dumps(body).encode() if body is not None else None)
    with urllib.request.urlopen(req) as r:
        return json.loads(r.read() or b"{}")


for _ in range(100):
    try:
        urllib.request.urlopen(url + "/v1/info")
        break
    except Exception:
        time.sleep(0.1)
call("POST", "/v1/account/signup", {"email": email, "password": password})
code = None
for _ in range(50):
    if os.path.isdir(outbox):
        for f in sorted(os.listdir(outbox)):
            m = json.load(open(os.path.join(outbox, f)))
            if m.get("to") == email:
                code = m["code"]
    if code:
        break
    time.sleep(0.1)
s = call("POST", "/v1/account/verify", {"email": email, "code": code, "install_id": "seed-device", "device_name": "Seeder"})
open(token_file, "w").write(s["token"])
print("NG Account made")

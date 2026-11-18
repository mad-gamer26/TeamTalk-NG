#!/bin/sh
# NG Account end to end through the app itself, on the Mac: a private copy
# of the service (ngmon, mail to an outbox, its own empty data) on a free
# local port, an account made and given a server through the service's API
# (as another device would), then the app's UI test in the Simulator
# (apps/ios/UITests): sign in, the server arrives, a server typed in the
# app reaches the account, sign out. Never the live service or the dev one.
#   scripts/test-ng-account-ui.sh [simulator id]
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
sim=${1:-4E71316B-6C2E-4BC1-B888-04BA890DB70F}
ngmon=${NGMON_BIN:-$HOME/ngmon-dev/bin/ngmon}
export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:$PATH"
work=$(mktemp -d)
port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
cat > "$work/ngmon.toml" <<TOML
listen = "127.0.0.1:$port"
allow_private_hosts = true
data_dir = "data"
packs_dir = "packs"
secret_key_file = "secret.key"
[push]
mode = "none"
[mail]
mode = "outbox"
outbox = "outbox"
TOML
(cd "$work" && "$ngmon" --config "$work/ngmon.toml" serve >"$work/ngmon.log" 2>&1) &
pid=$!
trap 'kill $pid 2>/dev/null; rm -rf "$work"' EXIT
url="http://127.0.0.1:$port"
email="ui-test@example.com"
password="ui test password 1"
python3 - "$url" "$email" "$password" "$work/outbox" <<'PY'
import json, os, sys, time, urllib.request
url, email, password, outbox = sys.argv[1:]
def call(method, path, body=None, token=None):
    req = urllib.request.Request(url + path, method=method, data=json.dumps(body).encode() if body is not None else None,
                                 headers={"Content-Type": "application/json", **({"Authorization": "Bearer " + token} if token else {})})
    with urllib.request.urlopen(req) as r:
        return json.loads(r.read() or b"{}")
for _ in range(100):
    try: urllib.request.urlopen(url + "/v1/catalog"); break
    except Exception: time.sleep(0.1)
call("POST", "/v1/account/signup", {"email": email, "password": password})
code = None
for _ in range(50):
    for f in sorted(os.listdir(outbox)) if os.path.isdir(outbox) else []:
        m = json.load(open(os.path.join(outbox, f)))
        if m.get("to") == email: code = m["code"]
    if code: break
    time.sleep(0.1)
s = call("POST", "/v1/account/verify", {"email": email, "code": code, "install_id": "seed-device", "device_name": "Seeder"})
call("POST", "/v1/sync", {"changes": [{"kind": "server", "key": "seed-1", "base_rev": 0, "deleted": False, "data": {
    "name": "Seeded Server", "ipaddr": "seeded.example.com", "tcpport": 10333, "udpport": 10333, "encrypted": False,
    "username": "", "nickname": "", "statusmsg": "", "channel": "", "sync_password": True, "password": "", "order": 0}}]}, s["token"])
open(os.environ.get("TMPDIR", "/tmp") + "/ttng-ui-seed-token", "w").write(s["token"])
print("account made and given a server")
PY
cd "$root/apps/ios"
xcodegen -q
xcrun simctl boot "$sim" 2>/dev/null || true
xcrun simctl uninstall "$sim" com.matthewdovi.TeamTalk-NG 2>/dev/null || true
TEST_RUNNER_NG_EMAIL="$email" TEST_RUNNER_NG_PASSWORD="$password" xcodebuild test \
    -project TeamTalkNG.xcodeproj -scheme TeamTalkNG -destination "platform=iOS Simulator,id=$sim" \
    -derivedDataPath build/uitest -only-testing:TeamTalkNGUITests TTNG_SERVICE_URL="$url" 2>&1 \
    > "$work/test.log" 2>&1 || true
grep -E "error:|^Test Case|\*\* TEST" "$work/test.log" | sort -u | head -20
if ! grep -q "\*\* TEST SUCCEEDED \*\*" "$work/test.log"; then
    echo "--- the service's log (last lines):"; tail -5 "$work/ngmon.log"
    echo "NG Account through the app: FAILED"; exit 1
fi
# The server typed in the app reached the account.
python3 - "$url" <<'PY'
import json, os, sys, urllib.request
token = open(os.environ.get("TMPDIR", "/tmp") + "/ttng-ui-seed-token").read()
os.remove(os.environ.get("TMPDIR", "/tmp") + "/ttng-ui-seed-token")
req = urllib.request.Request(sys.argv[1] + "/v1/sync?since=0", headers={"Authorization": "Bearer " + token})
names = [r["data"]["name"] for r in json.loads(urllib.request.urlopen(req).read())["records"] if r["kind"] == "server" and r.get("data")]
print("servers in the account:", names)
sys.exit(0 if "Typed Server" in names and "Seeded Server" in names else 1)
PY
echo "NG Account through the app: passed"

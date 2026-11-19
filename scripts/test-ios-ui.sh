#!/bin/sh
# Every UI test of the app, in the Simulator, on the Mac, against throwaway
# servers on localhost only (never a real TeamTalk server, the live or dev
# Monitor, or the live AudioNet):
#   * a TeamTalk server with people who act on the tests' say
#     (crates/ttng-core/examples/uitest_host.rs: admin, bob, carol);
#   * the private NG service (NG Account for publishing packs, the
#     catalog's packs.json, the relay; mail to an outbox) with an account;
#   * your own Monitor: ng-monitor on the Mac, paired for every test;
#   * a private AudioNet server with an account and this Mac as a visible
#     test device (its own sounds), when ~/audionet-ttng is built.
#   scripts/test-ios-ui.sh [simulator id] [-only-testing:TeamTalkNGUITests/Class[/test]]
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
sim=${1:-4E71316B-6C2E-4BC1-B888-04BA890DB70F}
only=${2:-}
export PATH="$HOME/.local/bin:$HOME/.cargo/bin:/opt/homebrew/bin:$PATH"
export LIBCLANG_PATH="${LIBCLANG_PATH:-$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain/usr/lib}"
# The UI rules a compiler can't check (the UI updates immediately).
"$root/scripts/check-ui-rules.sh"
work=$(mktemp -d)
pids=""
cleanup() { for p in $pids; do kill "$p" 2>/dev/null || true; done; rm -rf "$work"; }
trap cleanup EXIT

# The TeamTalk server and its people.
sdk="$root/sdk/macos"
(cd "$root" && CARGO_TARGET_DIR=target/uitest RUSTFLAGS="-C link-arg=-Wl,-rpath,$sdk/Library/TeamTalk_DLL" \
    TTNG_SDK_DIR="$sdk" cargo build -q -p ttng-core --example uitest_host)
TTNG_SIM="$sim" TTNG_SDK_DIR="$sdk" "$root/target/uitest/debug/examples/uitest_host" >"$work/host.out" 2>"$work/host.err" &
pids="$pids $!"
for _ in $(seq 1 100); do grep -q control_port "$work/host.out" 2>/dev/null && break; sleep 0.2; done
tt_port=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['tt_port'])" "$work/host.out")
control_port=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['control_port'])" "$work/host.out")
echo "TeamTalk server on $tt_port, its people on $control_port"

# A local web server: a sound pack's .zip for importing from a link, and
# the catalog's packs.json the service writes.
web_port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
mkdir -p "$work/web/catalog"

# The private NG service (the new one: NG Account for publishing packs,
# the catalog, the relay to your own Monitor), with an NG Account.
ngmon=${NGMON_BIN:-$HOME/ng-build/target/release/ng-service}
ng_port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
mkdir -p "$work/ngmon"
cat > "$work/ngmon/ngmon.toml" <<TOML
listen = "127.0.0.1:$ng_port"
allow_private_hosts = true
data_dir = "data"
packs_dir = "packs"
secret_key_file = "secret.key"
[catalog]
dir = "$work/web/catalog"
url = "http://127.0.0.1:$web_port/catalog"
[push]
mode = "none"
[mail]
mode = "outbox"
outbox = "outbox"
TOML
(cd "$work/ngmon" && exec "$ngmon" --config "$work/ngmon/ngmon.toml" serve >"$work/ngmon.log" 2>&1) &
pids="$pids $!"
ng_url="http://127.0.0.1:$ng_port"
catalog_url="http://127.0.0.1:$web_port/catalog/packs.json"
ng_email="ui-test@example.com"
ng_password="ui test password 1"
python3 "$root/scripts/uitest_seed_ng.py" "$ng_url" "$ng_email" "$ng_password" "$work/ngmon/outbox" "$work/ng-token"

# Your own Monitor: ng-monitor on this Mac, through the service's relay.
# Every test starts paired with it (a pairing made here, handed to the
# app; OWN_MONITOR); the pairing test types a fresh code, from OWN_CODE (a
# link to the current one).
own_code=""
own_monitor=""
own_name="UI Test PC"
own_bin=${NG_MONITOR_BIN:-$HOME/ng-build/target/release/ng-monitor}
phone_bin=${NG_TEST_PHONE_BIN:-$HOME/ng-build/target/release/examples/test-phone}
if [ -x "$own_bin" ] && [ -x "$phone_bin" ] && curl -fs "$ng_url/install.sh" >/dev/null 2>&1; then
    export NG_MONITOR_HOME="$work/own-monitor"
    "$own_bin" setup --relay "$ng_url" --name "$own_name" --no-service --no-pair >/dev/null
    "$own_bin" run 2>"$work/own-monitor.log" &
    pids="$pids $!"
    for _ in $(seq 1 100); do "$own_bin" status | grep -q "connected to the relay;" && break; sleep 0.2; done
    next_code() {
        "$own_bin" pair >"$work/own-pair.out" 2>&1 &
        pids="$pids $!"
        code=""
        for _ in $(seq 1 100); do code=$(grep -oE '[A-Z0-9]{4}-[0-9]{4}-[0-9]{4}' "$work/own-pair.out" || true); [ -n "$code" ] && break; sleep 0.2; done
    }
    next_code
    phone_key=$(head -c 32 /dev/urandom | base64)
    paired=$(PHONE_KEY="$phone_key" PAIR_ONLY=1 "$phone_bin" "$ng_url" "$code")
    own_monitor=$(python3 -c 'import json,sys; m=json.loads(sys.argv[1]); m["phone_key"]=sys.argv[2]; print(json.dumps(m))' "$paired" "$phone_key")
    # A fresh code for the pairing test whenever it asks (codes last 10
    # minutes): `pair` ends once used or expired, then there's another.
    (
        while true; do
            "$own_bin" pair >"$work/own-pair-loop.out" 2>&1 &
            p=$!
            for _ in $(seq 1 100); do c=$(grep -oE '[A-Z0-9]{4}-[0-9]{4}-[0-9]{4}' "$work/own-pair-loop.out" || true); [ -n "$c" ] && break; sleep 0.2; done
            printf '%s' "$c" >"$work/web/own-code.txt"
            wait $p || true
            : >"$work/web/own-code.txt"
            sleep 1
        done
    ) &
    pids="$pids $!"
    own_code="http://127.0.0.1:$web_port/own-code.txt"
    unset NG_MONITOR_HOME
    echo "Own Monitor \"$own_name\" on this Mac: the tests' pairing and a code ready"
else
    echo "No ng-monitor or test-phone in ~/ng-build, or no relay in $ngmon: the Monitor tests skip"
fi

# A sound pack's .zip on a local web server, for importing from a link.
mkdir -p "$work/web/pack"
cp "$root/apps/ios/TeamTalkNG/Sounds/logged_on.wav" "$root/apps/ios/TeamTalkNG/Sounds/user_msg.wav" "$work/web/pack/"
(cd "$work/web/pack" && zip -q "../Link pack.zip" logged_on.wav user_msg.wav)
(cd "$work/web" && exec python3 -m http.server "$web_port" --bind 127.0.0.1 >"$work/web.log" 2>&1) &
pids="$pids $!"
pack_url="http://127.0.0.1:$web_port/Link%20pack.zip"

# AudioNet: a private server, an account, this Mac as a visible device.
an_env=""
an=$HOME/audionet-ttng
if [ -x "$an/target/release/audionet-server" ] && [ -x "$an/target/release/audionet" ]; then
    an_port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
    an_url="http://127.0.0.1:$an_port"
    an_password="audionet test pass"
    printf 'public_url = "%s"\nbind = "127.0.0.1:%s"\ndatabase = "%s"\nweb_root = "%s"\n' \
        "$an_url" "$an_port" "$work/an.db" "$an/web" > "$work/an.toml"
    printf '%s\n' "$an_password" | "$an/target/release/audionet-server" -c "$work/an.toml" user add tester >/dev/null 2>&1
    "$an/target/release/audionet-server" -c "$work/an.toml" serve >"$work/an.log" 2>&1 &
    pids="$pids $!"
    for _ in $(seq 1 50); do curl -s "$an_url/api/v1/info" >/dev/null && break; sleep 0.2; done
    printf '%s\n' "$an_password" | "$an/target/release/audionet" node sign-in --server "$an_url" --user tester \
        --password-stdin --name "Mac test device" --config "$work/node.toml" >/dev/null
    "$an/target/release/audionet" node run --config "$work/node.toml" >"$work/node.log" 2>&1 &
    pids="$pids $!"
    an_env="TEST_RUNNER_AN_URL=$an_url TEST_RUNNER_AN_USER=tester TEST_RUNNER_AN_PASSWORD=$an_password"
    echo "AudioNet server on $an_port, this Mac its test device"
else
    echo "AudioNet not built in $an (cargo build --release -p audionet-server -p audionet-cli): its tests skip"
fi

cd "$root/apps/ios"
xcodegen -q
xcrun simctl boot "$sim" 2>/dev/null || true
# The microphone without asking (the Simulator's; the tests talk).
xcrun simctl privacy "$sim" grant microphone com.matthewdovi.TeamTalk-NG 2>/dev/null || true
# The old development app (TTNG Dev) also opens teamtalkng:// links: gone,
# so the tests' links reach this one.
xcrun simctl uninstall "$sim" com.matthewdovi.TeamTalk-NG.dev 2>/dev/null || true
set +e
env TEST_RUNNER_TT_PORT="$tt_port" TEST_RUNNER_CONTROL_PORT="$control_port" \
    TEST_RUNNER_NG_EMAIL="$ng_email" TEST_RUNNER_NG_PASSWORD="$ng_password" TEST_RUNNER_NG_URL="$ng_url" TEST_RUNNER_NG_OUTBOX="$work/ngmon/outbox" \
    TEST_RUNNER_OWN_CODE="$own_code" TEST_RUNNER_OWN_NAME="$own_name" TEST_RUNNER_OWN_MONITOR="$own_monitor" TEST_RUNNER_CATALOG_URL="$catalog_url" \
    TEST_RUNNER_PACK_URL="$pack_url" TEST_RUNNER_AN_URL="${an_url:-}" TEST_RUNNER_AN_USER=tester TEST_RUNNER_AN_PASSWORD="${an_password:-}" \
    xcodebuild test -project TeamTalkNG.xcodeproj -scheme TeamTalkNG \
    -destination "platform=iOS Simulator,id=$sim" -derivedDataPath build/uitest \
    ${only:+"$only"} TTNG_SERVICE_URL="$ng_url" TTNG_CATALOG_URL="$catalog_url" >"$work/test.log" 2>&1
set -e
grep -E "error:|^Test Case .*(passed|failed)|Executed [0-9]+ test|\*\* TEST" "$work/test.log" | sort -u | grep -v "^$" | tail -80
cp "$work/test.log" /tmp/ttng-uitest-last.log
if ! grep -q "\*\* TEST SUCCEEDED \*\*" "$work/test.log"; then
    echo "--- host:"; tail -5 "$work/host.err"
    echo "UI tests: FAILED (full log /tmp/ttng-uitest-last.log)"; exit 1
fi
echo "UI tests: passed"

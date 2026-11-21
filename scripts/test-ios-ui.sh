#!/bin/sh
# Every UI test of the app, in the Simulator, on the Mac, against throwaway
# servers on localhost only (never a real TeamTalk server, the live or dev
# Monitor, or the live AudioNet). Each lane has its own world:
#   * a TeamTalk server with people who act on the tests' say
#     (crates/ttng-core/examples/uitest_host.rs: admin, bob, carol);
#   * the private NG service (NG Account for publishing packs, the
#     catalog's packs.json, the relay; mail to an outbox) with an account;
#   * your own Monitor: ng-monitor on the Mac, paired for every test;
#   * a private AudioNet server with an account and this Mac as a visible
#     test device (its own sounds), when ~/audionet-ttng is built.
# The app is built once; the test classes are split over LANES Simulators
# (default 4, the longest first by the last run's times) that run at once.
# The iCloud tests stay on the first (the suite's own, signed-in) Simulator.
#   scripts/test-ios-ui.sh [simulator id] [-only-testing:TeamTalkNGUITests/Class[/test]]
#   LANES=1 scripts/test-ios-ui.sh       one Simulator, as before
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
sim=${1:-4E71316B-6C2E-4BC1-B888-04BA890DB70F}
only=${2:-}
lanes=${LANES:-4}
[ -n "$only" ] && lanes=1
export PATH="$HOME/.local/bin:$HOME/.cargo/bin:/opt/homebrew/bin:$PATH"
export LIBCLANG_PATH="${LIBCLANG_PATH:-$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain/usr/lib}"
# The UI rules a compiler can't check (the UI updates immediately).
"$root/scripts/check-ui-rules.sh"
work=$(mktemp -d)
pids=""
cleanup() { for p in $pids; do kill "$p" 2>/dev/null || true; done; rm -rf "$work"; }
trap cleanup EXIT
times="$HOME/.cache/ttng-uitest-times"
mkdir -p "$(dirname "$times")"

sdk="$root/sdk/macos"
(cd "$root" && CARGO_TARGET_DIR=target/uitest RUSTFLAGS="-C link-arg=-Wl,-rpath,$sdk/Library/TeamTalk_DLL" \
    TTNG_SDK_DIR="$sdk" cargo build -q -p ttng-core --example uitest_host)

# One lane's world in $lw for the Simulator $lsim; its settings for the
# tests in $lw/env (TEST_RUNNER_… lines).
start_world() {
    # The TeamTalk server and its people.
    TTNG_SIM="$lsim" TTNG_SDK_DIR="$sdk" "$root/target/uitest/debug/examples/uitest_host" >"$lw/host.out" 2>"$lw/host.err" &
    pids="$pids $!"
    for _ in $(seq 1 100); do grep -q control_port "$lw/host.out" 2>/dev/null && break; sleep 0.2; done
    tt_port=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['tt_port'])" "$lw/host.out")
    control_port=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['control_port'])" "$lw/host.out")
    echo "TeamTalk server on $tt_port, its people on $control_port"

    # A local web server: a sound pack's .zip for importing from a link, and
    # the catalog's packs.json the service writes.
    web_port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
    mkdir -p "$lw/web/catalog"

    # The private NG service (the new one: NG Account for publishing packs,
    # the catalog, the relay to your own Monitor), with an NG Account.
    ngmon=${NGMON_BIN:-$HOME/ng-build/target/release/ng-service}
    ng_port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
    mkdir -p "$lw/ngmon"
    cat > "$lw/ngmon/ngmon.toml" <<TOML
listen = "127.0.0.1:$ng_port"
allow_private_hosts = true
data_dir = "data"
packs_dir = "packs"
secret_key_file = "secret.key"
[catalog]
dir = "$lw/web/catalog"
url = "http://127.0.0.1:$web_port/catalog"
[push]
mode = "none"
[mail]
mode = "outbox"
outbox = "outbox"
TOML
    (cd "$lw/ngmon" && exec "$ngmon" --config "$lw/ngmon/ngmon.toml" serve >"$lw/ngmon.log" 2>&1) &
    pids="$pids $!"
    ng_url="http://127.0.0.1:$ng_port"
    catalog_url="http://127.0.0.1:$web_port/catalog/packs.json"
    ng_email="ui-test@example.com"
    ng_password="ui test password 1"
    python3 "$root/scripts/uitest_seed_ng.py" "$ng_url" "$ng_email" "$ng_password" "$lw/ngmon/outbox" "$lw/ng-token"

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
        export NG_MONITOR_HOME="$lw/own-monitor"
        "$own_bin" setup --relay "$ng_url" --name "$own_name" --no-service --no-pair >/dev/null
        "$own_bin" run 2>"$lw/own-monitor.log" &
        pids="$pids $!"
        for _ in $(seq 1 100); do "$own_bin" status | grep -q "connected to the relay;" && break; sleep 0.2; done
        next_code() {
            "$own_bin" pair >"$lw/own-pair.out" 2>&1 &
            pids="$pids $!"
            code=""
            for _ in $(seq 1 100); do code=$(grep -oE '[A-Z0-9]{4}-[0-9]{4}-[0-9]{4}' "$lw/own-pair.out" || true); [ -n "$code" ] && break; sleep 0.2; done
        }
        next_code
        phone_key=$(head -c 32 /dev/urandom | base64)
        paired=$(PHONE_KEY="$phone_key" PAIR_ONLY=1 "$phone_bin" "$ng_url" "$code")
        own_monitor=$(python3 -c 'import json,sys; m=json.loads(sys.argv[1]); m["phone_key"]=sys.argv[2]; print(json.dumps(m))' "$paired" "$phone_key")
        # A fresh code for the pairing test whenever it asks (codes last 10
        # minutes): `pair` ends once used or expired, then there's another.
        (
            while true; do
                "$own_bin" pair >"$lw/own-pair-loop.out" 2>&1 &
                p=$!
                for _ in $(seq 1 100); do c=$(grep -oE '[A-Z0-9]{4}-[0-9]{4}-[0-9]{4}' "$lw/own-pair-loop.out" || true); [ -n "$c" ] && break; sleep 0.2; done
                printf '%s' "$c" >"$lw/web/own-code.txt"
                wait $p || true
                : >"$lw/web/own-code.txt"
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
    mkdir -p "$lw/web/pack"
    cp "$root/apps/ios/TeamTalkNG/Sounds/logged_on.wav" "$root/apps/ios/TeamTalkNG/Sounds/user_msg.wav" "$lw/web/pack/"
    (cd "$lw/web/pack" && zip -q "../Link pack.zip" logged_on.wav user_msg.wav)
    (cd "$lw/web" && exec python3 -m http.server "$web_port" --bind 127.0.0.1 >"$lw/web.log" 2>&1) &
    pids="$pids $!"
    pack_url="http://127.0.0.1:$web_port/Link%20pack.zip"

    # AudioNet: a private server, an account, this Mac as a visible device.
    an_env=""
    an=$HOME/audionet-ttng
    if [ -x "$an/target/release/audionet-server" ] && [ -x "$an/target/release/audionet" ]; then
        an_port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
        an_url="http://127.0.0.1:$an_port"
        an_password="audionet test pass"
        # Its admin page on a port of its own too (its default is fixed: a
        # second lane's server wouldn't start).
        an_admin=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
        printf 'public_url = "%s"\nbind = "127.0.0.1:%s"\ndatabase = "%s"\nweb_root = "%s"\n[admin]\nbind = "127.0.0.1:%s"\n' \
            "$an_url" "$an_port" "$lw/an.db" "$an/web" "$an_admin" > "$lw/an.toml"
        printf '%s\n' "$an_password" | "$an/target/release/audionet-server" -c "$lw/an.toml" user add tester >/dev/null 2>&1
        "$an/target/release/audionet-server" -c "$lw/an.toml" serve >"$lw/an.log" 2>&1 &
        pids="$pids $!"
        for _ in $(seq 1 50); do curl -s "$an_url/api/v1/info" >/dev/null && break; sleep 0.2; done
        printf '%s\n' "$an_password" | "$an/target/release/audionet" node sign-in --server "$an_url" --user tester \
            --password-stdin --name "Mac test device" --config "$lw/node.toml" >/dev/null
        "$an/target/release/audionet" node run --config "$lw/node.toml" >"$lw/node.log" 2>&1 &
        pids="$pids $!"
        an_env="TEST_RUNNER_AN_URL=$an_url TEST_RUNNER_AN_USER=tester TEST_RUNNER_AN_PASSWORD=$an_password"
        echo "AudioNet server on $an_port, this Mac its test device"
    else
        echo "AudioNet not built in $an (cargo build --release -p audionet-server -p audionet-cli): its tests skip"
    fi

    : >"$lw/env"
    put() { printf "export %s='%s'\n" "$1" "$(printf '%s' "$2" | sed "s/'/'\\\\''/g")" >>"$lw/env"; }
    put TEST_RUNNER_TT_PORT "$tt_port"; put TEST_RUNNER_CONTROL_PORT "$control_port"
    put TEST_RUNNER_NG_EMAIL "$ng_email"; put TEST_RUNNER_NG_PASSWORD "$ng_password"; put TEST_RUNNER_NG_URL "$ng_url"
    put TEST_RUNNER_NG_OUTBOX "$lw/ngmon/outbox"; put TEST_RUNNER_OWN_CODE "$own_code"; put TEST_RUNNER_OWN_NAME "$own_name"
    put TEST_RUNNER_OWN_MONITOR "$own_monitor"; put TEST_RUNNER_CATALOG_URL "$catalog_url"; put TEST_RUNNER_PACK_URL "$pack_url"
    put TEST_RUNNER_AN_URL "${an_url:-}"; put TEST_RUNNER_AN_USER tester; put TEST_RUNNER_AN_PASSWORD "${an_password:-}"
}

# The Simulators: the suite's own, then "TTNG UI lane N" made like it.
sims="$sim"
if [ "$lanes" -gt 1 ]; then
    info=$(xcrun simctl list devices -j | python3 -c '
import json,sys
d=json.load(sys.stdin)["devices"]
for rt,devs in d.items():
    for x in devs:
        if x["udid"]==sys.argv[1]: print(x["deviceTypeIdentifier"], rt)' "$sim")
    i=2
    while [ "$i" -le "$lanes" ]; do
        name="TTNG UI lane $i"
        id=$(xcrun simctl list devices | grep -F "$name (" | grep -oE '[0-9A-F-]{36}' | head -1 || true)
        [ -z "$id" ] && id=$(xcrun simctl create "$name" $info)
        sims="$sims $id"
        i=$((i + 1))
    done
fi

# Each Simulator ready within a time limit, or its lane is left out (a
# broken Simulator once hung a whole run in `simctl privacy`).
limit() { t=$1; shift; perl -e 'alarm shift; exec @ARGV' "$t" "$@"; }
ready=""
for lsim in $sims; do
    limit 180 xcrun simctl bootstatus "$lsim" -b >/dev/null 2>&1 || { echo "Simulator $lsim didn't boot: its lane is left out"; continue; }
    # The microphone without asking (the Simulator's; the tests talk).
    rc=0; limit 60 xcrun simctl privacy "$lsim" grant microphone com.matthewdovi.TeamTalk-NG >/dev/null 2>&1 || rc=$?
    [ $rc -ge 128 ] && { echo "Simulator $lsim hung: its lane is left out"; continue; }
    # The old development app (TTNG Dev) also opens teamtalkng:// links:
    # gone, so the tests' links reach this one.
    limit 60 xcrun simctl uninstall "$lsim" com.matthewdovi.TeamTalk-NG.dev >/dev/null 2>&1 || true
    ready="$ready $lsim"
done
sims=$ready
lanes=$(echo $sims | wc -w | tr -d ' ')
[ "$lanes" -ge 1 ] || { echo "UI tests: no Simulator ready"; exit 1; }

n=0
for lsim in $sims; do
    n=$((n + 1)); lw="$work/lane$n"; mkdir -p "$lw"
    echo "lane $n ($lsim):"
    start_world
done

cd "$root/apps/ios"
xcodegen -q
# Built once. The service's address is each lane's (UITEST_SERVICE_URL, at
# every test's start); the build's own is a dead one, never the live service.
set +e
xcodebuild build-for-testing -project TeamTalkNG.xcodeproj -scheme TeamTalkNG \
    -destination "platform=iOS Simulator,id=$sim" -derivedDataPath build/uitest \
    TTNG_SERVICE_URL="http://127.0.0.1:9" TTNG_CATALOG_URL="http://127.0.0.1:9/packs.json" >"$work/build.log" 2>&1
built=$?
set -e
if [ $built -ne 0 ]; then
    grep -E "error:" "$work/build.log" | sort -u | head -30
    cp "$work/build.log" /tmp/ttng-uitest-last.log
    echo "UI tests: the build FAILED (full log /tmp/ttng-uitest-last.log)"; exit 1
fi

# The classes, split: the longest first onto the lane with least so far;
# the iCloud ones on lane 1 (the signed-in Simulator).
if [ -n "$only" ]; then
    echo "$only" >"$work/lane1/only"
else
    grep -hoE '^(final )?class [A-Za-z]+: (NGTestCase|XCTestCase)' UITests/*.swift | awk '{print $(NF-1)}' | tr -d ':' >"$work/classes"
    python3 - "$work" "$lanes" "$times" <<'PY'
import os, sys
work, lanes, times = sys.argv[1], int(sys.argv[2]), sys.argv[3]
classes = [c for c in open(f"{work}/classes").read().split() if c != "NGTestCase"]
t = {}
if os.path.exists(times):
    for line in open(times):
        c, _, s = line.partition(" ")
        if s: t[c] = float(s)
pinned = {"ICloudSignInUITests", "KeychainMergeUITests", "ICloudEraseSafetyUITests", "PackCloudReinstallUITests", "FilesSettingsUITests"}
load = [0.0] * lanes
plan = [[] for _ in range(lanes)]
for c in sorted(classes, key=lambda c: -t.get(c, 120)):
    i = 0 if c in pinned else min(range(lanes), key=lambda i: load[i])
    plan[i].append(c); load[i] += t.get(c, 120)
for i, cs in enumerate(plan):
    open(f"{work}/lane{i+1}/only", "w").write(" ".join(f"-only-testing:TeamTalkNGUITests/{c}" for c in cs))
    print(f"lane {i+1}: {len(cs)} classes, about {int(load[i] / 60)} min")
PY
fi

# All lanes at once.
n=0; runs=""
for lsim in $sims; do
    n=$((n + 1)); lw="$work/lane$n"
    [ -s "$lw/only" ] || continue
    (
        set +e
        . "$lw/env"
        xcodebuild test-without-building -project TeamTalkNG.xcodeproj -scheme TeamTalkNG \
            -destination "platform=iOS Simulator,id=$lsim" -derivedDataPath build/uitest \
            $(cat "$lw/only") >"$lw/test.log" 2>&1
        echo $? >"$lw/status"
    ) &
    runs="$runs $!"
done
for p in $runs; do wait "$p" || true; done

cat "$work"/lane*/test.log >"$work/test.log"
grep -E "error:|^Test Case .*(passed|failed)|Executed [0-9]+ test|\*\* TEST" "$work/test.log" | sort -u | grep -v "^$" | tail -80
cp "$work/test.log" /tmp/ttng-uitest-last.log
# Each class's time, for the next run's split.
python3 - "$work/test.log" "$times" <<'PY'
import os, re, sys
t = {}
if os.path.exists(sys.argv[2]):
    for line in open(sys.argv[2]):
        c, _, s = line.partition(" ")
        if s: t[c] = float(s)
run = {}
for m in re.finditer(r"Test Case '-\[TeamTalkNGUITests\.(\w+) \w+\]' (?:passed|failed) \((\d+\.\d+) seconds\)", open(sys.argv[1], errors="replace").read()):
    run[m[1]] = run.get(m[1], 0) + float(m[2])
t.update(run)
open(sys.argv[2], "w").write("".join(f"{c} {s:.0f}\n" for c, s in sorted(t.items())))
PY
failed=0
for st in "$work"/lane*/status; do [ "$(cat "$st")" = 0 ] || failed=1; done
if [ $failed -ne 0 ] || grep -q "^Test Case .* failed" "$work/test.log"; then
    for h in "$work"/lane*/host.err; do echo "--- host ($h):"; tail -3 "$h"; done
    echo "UI tests: FAILED (full log /tmp/ttng-uitest-last.log)"; exit 1
fi
echo "UI tests: passed ($(grep -c '^Test Case .* passed' "$work/test.log") tests)"

#!/bin/sh
# Every UI test of the app, in the Simulator, on the Mac, against throwaway
# servers on localhost only (never a real TeamTalk server, the live or dev
# Monitor, or the live AudioNet):
#   * a TeamTalk server with people who act on the tests' say
#     (crates/ttng-core/examples/uitest_host.rs: admin, bob, carol);
#   * a private ngmon (Monitor and NG Account; mail to an outbox) with an
#     NG Account that has a server in it;
#   * a private AudioNet server with an account and this Mac as a visible
#     test device (its own sounds), when ~/audionet-ttng is built.
#   scripts/test-ios-ui.sh [simulator id] [-only-testing:TeamTalkNGUITests/Class[/test]]
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
sim=${1:-4E71316B-6C2E-4BC1-B888-04BA890DB70F}
only=${2:-}
export PATH="$HOME/.local/bin:$HOME/.cargo/bin:/opt/homebrew/bin:$PATH"
export LIBCLANG_PATH="${LIBCLANG_PATH:-$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain/usr/lib}"
work=$(mktemp -d)
pids=""
cleanup() { for p in $pids; do kill "$p" 2>/dev/null || true; done; rm -rf "$work"; }
trap cleanup EXIT

# The TeamTalk server and its people.
sdk="$root/sdk/macos"
(cd "$root" && CARGO_TARGET_DIR=target/uitest RUSTFLAGS="-C link-arg=-Wl,-rpath,$sdk/Library/TeamTalk_DLL" \
    TTNG_SDK_DIR="$sdk" cargo build -q -p ttng-core --example uitest_host)
TTNG_SDK_DIR="$sdk" "$root/target/uitest/debug/examples/uitest_host" >"$work/host.out" 2>"$work/host.err" &
pids="$pids $!"
for _ in $(seq 1 100); do grep -q control_port "$work/host.out" 2>/dev/null && break; sleep 0.2; done
tt_port=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['tt_port'])" "$work/host.out")
control_port=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['control_port'])" "$work/host.out")
echo "TeamTalk server on $tt_port, its people on $control_port"

# The private ngmon, with an NG Account that has a server.
ngmon=${NGMON_BIN:-$HOME/ngmon-dev/bin/ngmon}
ng_port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
mkdir -p "$work/ngmon"
cat > "$work/ngmon/ngmon.toml" <<TOML
listen = "127.0.0.1:$ng_port"
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
(cd "$work/ngmon" && exec "$ngmon" --config "$work/ngmon/ngmon.toml" serve >"$work/ngmon.log" 2>&1) &
pids="$pids $!"
ng_url="http://127.0.0.1:$ng_port"
ng_email="ui-test@example.com"
ng_password="ui test password 1"
python3 "$root/scripts/uitest_seed_ng.py" "$ng_url" "$ng_email" "$ng_password" "$work/ngmon/outbox" "$work/ng-token"

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
set +e
env TEST_RUNNER_TT_PORT="$tt_port" TEST_RUNNER_CONTROL_PORT="$control_port" \
    TEST_RUNNER_NG_EMAIL="$ng_email" TEST_RUNNER_NG_PASSWORD="$ng_password" \
    TEST_RUNNER_AN_URL="${an_url:-}" TEST_RUNNER_AN_USER=tester TEST_RUNNER_AN_PASSWORD="${an_password:-}" \
    xcodebuild test -project TeamTalkNG.xcodeproj -scheme TeamTalkNG \
    -destination "platform=iOS Simulator,id=$sim" -derivedDataPath build/uitest \
    ${only:+"$only"} TTNG_SERVICE_URL="$ng_url" >"$work/test.log" 2>&1
set -e
grep -E "error:|^Test Case .*(passed|failed)|Executed [0-9]+ test|\*\* TEST" "$work/test.log" | sort -u | grep -v "^$" | tail -80
cp "$work/test.log" /tmp/ttng-uitest-last.log
if ! grep -q "\*\* TEST SUCCEEDED \*\*" "$work/test.log"; then
    echo "--- host:"; tail -5 "$work/host.err"
    echo "UI tests: FAILED (full log /tmp/ttng-uitest-last.log)"; exit 1
fi
echo "UI tests: passed"

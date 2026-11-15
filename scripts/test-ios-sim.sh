#!/bin/bash
# Runs the core's tests inside the iOS Simulator, against the SDK built
# from source (scripts/build-sdk-apple.sh ios-arm64-simulator). On a Mac,
# with a Simulator booted. The Simulator shares the Mac's network, so the
# tests' tt5srv (the Mac SDK's: scripts/fetch-sdk.sh macos) and openssl run
# on the Mac as usual.
#   scripts/test-ios-sim.sh [test name filter]
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
export PATH=/opt/homebrew/bin:$HOME/.cargo/bin:$PATH
export IPHONEOS_DEPLOYMENT_TARGET=${IPHONEOS_DEPLOYMENT_TARGET:-17.0}
export LIBCLANG_PATH=${LIBCLANG_PATH:-$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain/usr/lib}
[ -f sdk/ios-src/Library/TeamTalk_DLL/libTeamTalk5-arm64-simulator.a ] || {
    echo "No Simulator SDK: scripts/build-sdk-apple.sh ios-arm64-simulator" >&2; exit 1; }
xcrun simctl list devices booted | grep -q Booted || { echo "Boot a Simulator first" >&2; exit 1; }
bins=$(TTNG_SDK_DIR=$ROOT/sdk/ios-src cargo test --release -p ttng-core --target aarch64-apple-ios-sim --no-run 2>&1 |
    grep -oE "target/aarch64-apple-ios-sim/release/deps/[a-z_0-9]+-[0-9a-f]+")
failed=0
for b in $bins; do
    echo "== $(basename "$b" | sed 's/-[0-9a-f]*$//')"
    # Variables reach the Simulator's process with SIMCTL_CHILD_.
    out=$(SIMCTL_CHILD_TTNG_SDK_DIR=$ROOT/sdk/macos SIMCTL_CHILD_OPENSSL=$(command -v openssl) \
        xcrun simctl spawn booted "$b" --test-threads=1 "$@" 2>&1 || true)
    grep -E "^test |^test result|panicked" <<<"$out" || true
    grep -q "^test result: ok" <<<"$out" || failed=1
done
[ $failed = 0 ] && echo "All passed in the Simulator" || { echo "Some failed" >&2; exit 1; }

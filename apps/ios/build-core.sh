#!/bin/sh
# Builds TeamTalk NG's core (crates/ttng-ffi, with BearWare's official SDK
# linked in) for iPhone as Generated/TeamTalkCore.xcframework, and generates
# its Swift bindings into Generated/. Then: cd apps/ios && xcodegen generate
#
# With the SDK built from source (scripts/build-sdk-apple.sh, into
# sdk/ios-src: FFmpeg, and an Apple silicon simulator library) it's used,
# for iPhones and the Simulator; otherwise BearWare's official SDK
# (scripts/fetch-sdk.sh ios), for iPhones only. Either way the bindings
# come from the Mac build (scripts/fetch-sdk.sh macos).
set -eu
export IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-17.0}"
export LIBCLANG_PATH="${LIBCLANG_PATH:-$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain/usr/lib}"
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
out="$here/Generated"
rm -rf "$out"
mkdir -p "$out/include"
cd "$root"
targets="aarch64-apple-ios"
if [ -z "${TTNG_SDK_DIR:-}" ] && [ -f "$root/sdk/ios-src/Library/TeamTalk_DLL/libTeamTalk5-arm64.a" ]; then
    ios_sdk="$root/sdk/ios-src"
    [ -f "$ios_sdk/Library/TeamTalk_DLL/libTeamTalk5-arm64-simulator.a" ] && targets="$targets aarch64-apple-ios-sim"
    echo "Using the SDK built from source ($(cat "$ios_sdk/.version" 2>/dev/null)): $targets"
else
    ios_sdk="${TTNG_SDK_DIR:-$root/sdk/ios}"
fi
for t in $targets; do
    TTNG_SDK_DIR="$ios_sdk" cargo build --release -p ttng-ffi --target "$t"
done
# Bindings from the Mac build of the same crate (identical interface).
cargo build --release -p ttng-ffi
cargo run --release -q -p ttng-ffi --features bindgen --bin uniffi-bindgen -- \
    generate --library target/release/libttng_ffi.dylib --language swift --out-dir "$out" 2>/dev/null
mv "$out/ttng_ffiFFI.h" "$out/include/"
mv "$out/ttng_ffiFFI.modulemap" "$out/include/module.modulemap"
libs=""
for t in $targets; do libs="$libs -library target/$t/release/libttng_ffi.a -headers $out/include"; done
# shellcheck disable=SC2086
xcodebuild -create-xcframework $libs -output "$out/TeamTalkCore.xcframework" >/dev/null
rm -rf "$out/include"
echo "Core and Swift bindings in $out"

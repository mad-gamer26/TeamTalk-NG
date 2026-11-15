#!/bin/sh
# Builds AudioNet's engine for TeamTalk NG from an AudioNet source checkout
# (default: ~/audionet-ttng, a checkout of its own kept on origin/main, so
# the owner's working copy is never touched; it must be as new as the
# server, which refuses older clients), for iPhones and the Apple silicon
# Simulator:
#   scripts/build-audionet.sh [/path/to/AudioNet]
# Produces apps/ios/AudioNet/AudioNetCore.xcframework and
# audionet_ffi.swift (compiled into the AudioNetKit framework, a Swift
# module of its own so its names don't meet the core's).
#
# The engine is pre-linked into one object that exports only its Swift
# interface (as the old app did): AudioNet and the TeamTalk SDK both contain
# libopus, and NG's core is Rust too; this keeps AudioNet's copies private,
# so neither resolves the other's symbols. Not committed (built, like the
# core); kept apart from apps/ios/Generated, which build-core.sh clears.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
src=${1:-$HOME/audionet-ttng}
src=$(cd "$src" && pwd)
out="$root/apps/ios/AudioNet"
export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:$PATH"
export IPHONEOS_DEPLOYMENT_TARGET=17.0
"$src/apps/ios/build-core.sh"
generated="$src/apps/ios/Generated"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
args=""
for t in aarch64-apple-ios:iphoneos:arm64-apple-ios17.0 aarch64-apple-ios-sim:iphonesimulator:arm64-apple-ios17.0-simulator; do
    triple=${t%%:*}; rest=${t#*:}; sdk=${rest%%:*}; target=${rest#*:}
    lib="$src/target/$triple/release/libaudionet_ffi.a"
    nm -g --defined-only "$lib" 2>/dev/null \
        | awk 'NF == 3 && ($3 ~ /^_uniffi_audionet_ffi_/ || $3 ~ /^_ffi_audionet_ffi_/) { print $3 }' \
        | sort -u > "$work/exports-$sdk.txt"
    test -s "$work/exports-$sdk.txt"
    mkdir -p "$work/$sdk"
    xcrun -sdk "$sdk" clang -target "$target" -r -nostdlib \
        -Wl,-force_load,"$lib" \
        -Wl,-exported_symbols_list,"$work/exports-$sdk.txt" \
        -o "$work/$sdk/audionet_core.o"
    xcrun ar rcs "$work/$sdk/libaudionet_core.a" "$work/$sdk/audionet_core.o"
    args="$args -library $work/$sdk/libaudionet_core.a -headers $work/include"
done
# Its headers in a folder of their own: Xcode puts every xcframework's
# headers in one place, and the core has a module.modulemap too.
mkdir -p "$work/include/audionet_ffiFFI"
cp "$generated/AudioNetCore.xcframework/ios-arm64/Headers/"* "$work/include/audionet_ffiFFI/"
rm -rf "$out"
mkdir -p "$out"
# shellcheck disable=SC2086
xcodebuild -create-xcframework $args -output "$out/AudioNetCore.xcframework" >/dev/null
cp "$generated/audionet_ffi.swift" "$out/audionet_ffi.swift"
echo "AudioNet engine and Swift interface in $out ($(cd "$src" && git log --oneline -1))"

#!/bin/sh
# Builds AudioNet's engine for TeamTalk NG from an AudioNet source checkout:
#   AudioNet/build-audionet-core.sh /path/to/AudioNet
# Produces AudioNet/AudioNetCore.xcframework (iPhone) and
# AudioNet/audionet_ffi.swift (its Swift interface).
#
# The engine is pre-linked into one object that exports only its Swift
# interface: AudioNet and the TeamTalk SDK both contain libopus, and this
# keeps AudioNet's copy (and the rest of its internals) private, so the two
# never resolve each other's symbols.
set -eu
src=${1:?usage: build-audionet-core.sh /path/to/AudioNet}
src=$(cd "$src" && pwd)
here=$(cd "$(dirname "$0")" && pwd)
export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:$PATH"
# Same oldest iOS as TeamTalk NG.
export IPHONEOS_DEPLOYMENT_TARGET=17.0
"$src/apps/ios/build-core.sh"
generated="$src/apps/ios/Generated"
lib="$src/target/aarch64-apple-ios/release/libaudionet_ffi.a"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
nm -g --defined-only "$lib" 2>/dev/null \
    | awk 'NF == 3 && ($3 ~ /^_uniffi_audionet_ffi_/ || $3 ~ /^_ffi_audionet_ffi_/) { print $3 }' \
    | sort -u > "$work/exports.txt"
test -s "$work/exports.txt"
xcrun -sdk iphoneos clang -target arm64-apple-ios17.0 -r -nostdlib \
    -Wl,-force_load,"$lib" \
    -Wl,-exported_symbols_list,"$work/exports.txt" \
    -o "$work/audionet_core.o"
mkdir -p "$work/lib" "$work/include"
xcrun ar rcs "$work/lib/libaudionet_core.a" "$work/audionet_core.o"
cp "$generated/AudioNetCore.xcframework/ios-arm64/Headers/"* "$work/include/"
rm -rf "$here/AudioNetCore.xcframework"
xcodebuild -create-xcframework \
    -library "$work/lib/libaudionet_core.a" -headers "$work/include" \
    -output "$here/AudioNetCore.xcframework" >/dev/null
cp "$generated/audionet_ffi.swift" "$here/audionet_ffi.swift"
echo "AudioNet engine and Swift interface in $here"

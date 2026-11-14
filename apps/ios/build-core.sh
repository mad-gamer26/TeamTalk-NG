#!/bin/sh
# Builds TeamTalk NG's core (crates/ttng-ffi, with BearWare's official SDK
# linked in) for iPhone as Generated/TeamTalkCore.xcframework, and generates
# its Swift bindings into Generated/. Then: cd apps/ios && xcodegen generate
#
# Device only: the official iOS SDK has arm64 (devices) and x86_64 (Intel
# simulators) slices, so there's no Apple silicon simulator build.
# Needs scripts/fetch-sdk.sh ios macos first (macos for the bindings).
set -eu
export IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-17.0}"
export LIBCLANG_PATH="${LIBCLANG_PATH:-$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain/usr/lib}"
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
out="$here/Generated"
rm -rf "$out"
mkdir -p "$out/include"
cd "$root"
cargo build --release -p ttng-ffi --target aarch64-apple-ios
# Bindings from the Mac build of the same crate (identical interface).
cargo build --release -p ttng-ffi
cargo run --release -q -p ttng-ffi --features bindgen --bin uniffi-bindgen -- \
    generate --library target/release/libttng_ffi.dylib --language swift --out-dir "$out" 2>/dev/null
mv "$out/ttng_ffiFFI.h" "$out/include/"
mv "$out/ttng_ffiFFI.modulemap" "$out/include/module.modulemap"
xcodebuild -create-xcframework \
    -library target/aarch64-apple-ios/release/libttng_ffi.a -headers "$out/include" \
    -output "$out/TeamTalkCore.xcframework" >/dev/null
rm -rf "$out/include"
echo "Core and Swift bindings in $out"

#!/bin/bash
# Builds BearWare's TeamTalk 5 SDK from source (v5.23, pinned) for iPhone
# and the Apple silicon Simulator, with FFmpeg (BearWare's own option) so
# media files stream, into sdk/ios-src/ in the same layout as the official
# SDK (Library/TeamTalk_DLL/TeamTalk.h and one static library per slice).
# No changes to BearWare's code. Runs on a Mac; slow the first time (it
# builds its toolchain: OpenSSL, ACE, FFmpeg, WebRTC, codecs).
#   scripts/build-sdk-apple.sh [ios-arm64] [ios-arm64-simulator]
set -euo pipefail
export PATH=/opt/homebrew/opt/libtool/libexec/gnubin:/opt/homebrew/bin:$PATH
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SRC=${TTNG_SDK_SRC:-$HOME/teamtalk-sdk-src}
TAG=v5.23
COMMIT=a0d26fdf90f447d39784641a9bc7be060373f534
if [ ! -d "$SRC/.git" ]; then
    git clone -q --branch "$TAG" --depth 1 https://github.com/BearWare/TeamTalk5.git "$SRC"
    git -C "$SRC" submodule update --init --recursive --depth 1
fi
[ "$(git -C "$SRC" rev-parse HEAD)" = "$COMMIT" ] || { echo "$SRC isn't BearWare's $TAG ($COMMIT)" >&2; exit 1; }
cd "$SRC"
set +u  # env.sh reads variables that may be unset
source ./env.sh
set -u
cd Build
# WebRTC gets its own checkout (BearWare's build fetches it there, at the
# branch 5.23 pins, branch-heads/7778): BearWare's default, ~/webrtc/iOS,
# is skipped when it exists, whatever revision it holds.
WEBRTC_FETCH=${TTNG_WEBRTC_DIR:-$HOME/webrtc-ttng}/iOS
mkdir -p "$WEBRTC_FETCH"
# WebRTC links its build tools with Apple's linker (use_lld=false), which
# warns that Chromium's clang has no libLTO.dylib, and WebRTC makes
# linker warnings errors: they stay warnings. And no Clang modules: its
# module map for Darwin doesn't match Xcode 27's SDK (math.h needs
# std_float_h) either. Given through BearWare's own
# WEBRTC_CFG_EXTRA hook (empty for arm64), so no file of theirs changes;
# FORCE, or a value cached by an earlier run would stay.
# Its build tools are built for this Mac with an older macOS SDK (the
# Command Line Tools'), as Chromium's clang doesn't get on with Xcode
# 27's macOS headers (float.h's constants go missing); the iPhone code
# uses Xcode's iOS SDK as before.
HOST_SDK=${TTNG_HOST_SDK:-$(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX26*.sdk 2>/dev/null | grep -E '[0-9]\.sdk$' | sort -V | tail -1)}
[ -n "$HOST_SDK" ] || { echo "No macOS 26 SDK (xcode-select --install, or set TTNG_HOST_SDK)" >&2; exit 1; }
CACHE=$SRC/Build/ttng-webrtc.cmake
cat > "$CACHE" <<CMAKE
set(WEBRTC_CFG_EXTRA "fatal_linker_warnings=false use_clang_modules=false mac_sdk_path=\\"$HOST_SDK\\"" CACHE STRING "" FORCE)
set(WEBRTC_FETCH_PATH "$WEBRTC_FETCH" CACHE FILEPATH "" FORCE)
CMAKE
INSTALLDIR=$TEAMTALK_ROOT/Build/install-release-ios
targets=("$@")
[ ${#targets[@]} -gt 0 ] || targets=(ios-arm64 ios-arm64-simulator)
OUT=$ROOT/sdk/ios-src/Library/TeamTalk_DLL
mkdir -p "$OUT"
for t in "${targets[@]}"; do
    case "$t" in
        ios-arm64) sysroot=iphoneos; arch=arm64 ;;
        ios-arm64-simulator) sysroot=iphonesimulator; arch=arm64-simulator ;;
        *) echo "Unknown target $t" >&2; exit 2 ;;
    esac
    echo "== $t"
    # BearWare's FFmpeg settings build arm64 for iPhones only (their
    # Simulator case is Intel's): for the Apple silicon Simulator, the
    # `clang` FFmpeg calls by name is a wrapper that asks for the Simulator
    # instead. CMake's own compilers are full paths, so only FFmpeg sees it.
    SIMBIN=$SRC/Build/ttng-simulator-bin
    PATH_BEFORE=$PATH
    if [ "$t" = ios-arm64-simulator ]; then
        mkdir -p "$SIMBIN"
        cat > "$SIMBIN/clang" <<'WRAP'
#!/bin/bash
# For FFmpeg's Apple silicon Simulator build (scripts/build-sdk-apple.sh).
args=() sim=0
for a in "$@"; do
    case "$a" in
        -miphoneos-version-min=*) ;;
        -mios-simulator-version-min=*|*-apple-ios*-simulator) sim=1; args+=("$a") ;;
        *) args+=("$a") ;;
    esac
done
[ $sim = 1 ] || args=("-mios-simulator-version-min=${IPHONEOS_DEPLOYMENT_TARGET:-17.0}" "${args[@]}")
exec /usr/bin/clang "${args[@]}"
WRAP
        chmod +x "$SIMBIN/clang"
        export PATH=$SIMBIN:$PATH
    fi
    # BearWare's ios-build settings, with FFmpeg on.
    make BUILDDIR=build-release-$t CONFIGTYPE=release CMAKE_EXTRA="-C $CACHE -DCMAKE_SYSTEM_NAME=iOS \
        -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_SYSROOT=$sysroot -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 \
        -DTOOLCHAIN_INSTALL_PREFIX=$INSTALLDIR/$arch \
        -DBUILD_TEAMTALK_LIBRARY_LIB=ON -DBUILD_TEAMTALK_LIBRARY_LIBPRO=ON \
        -DBUILD_TEAMTALK_LIBRARY_DLL=OFF -DBUILD_TEAMTALK_LIBRARY_DLLPRO=OFF \
        -DBUILD_TEAMTALK_LIBRARIES=OFF -DBUILD_TEAMTALK_CLIENTS=OFF -DBUILD_TEAMTALK_SERVERS=OFF \
        -DBUILD_TEAMTALK_SERVER_SRVEXE=OFF -DBUILD_TEAMTALK_SERVER_SRVEXEPRO=OFF \
        -DBUILD_TEAMTALK_DOCUMENTATION=OFF \
        -DFEATURE_FFMPEG=ON -DTOOLCHAIN_FFMPEG=ON \
        -DFEATURE_OGG=OFF -DFEATURE_OPUSTOOLS=OFF \
        -DTOOLCHAIN_CATCH2=OFF -DTOOLCHAIN_OGG=OFF -DTOOLCHAIN_PORTAUDIO=OFF -DTOOLCHAIN_ZLIB=OFF" buildlib
    export PATH=$PATH_BEFORE
    # One static library: TeamTalk (Pro: with encryption), its toolchain,
    # and FFmpeg's libraries (BearWare's lipo-arch leaves those out).
    I=$INSTALLDIR/$arch
    /usr/bin/libtool -static -o "$OUT/libTeamTalk5-$arch.a" \
        "$I"/speex/lib/libspeex.a "$I"/speexdsp/lib/libspeexdsp.a "$I"/opus/lib/libopus.a "$I"/libvpx/lib/libvpx.a \
        "$I"/ace/lib/libACE.a "$I"/ace/lib/libACE_SSL.a "$I"/ace/lib/libACE_INet.a "$I"/ace/lib/libACE_INet_SSL.a \
        "$I"/openssl/lib/libcrypto.a "$I"/openssl/lib/libssl.a \
        "$I"/webrtc/obj/modules/audio_processing/libteamtalk.a \
        $(ls "$I"/ffmpeg/lib/*.a) \
        "$TEAMTALK_ROOT/Library/TeamTalk_DLL/$arch/libTeamTalk5Pro.a"
done
cp "$TEAMTALK_ROOT/Library/TeamTalk_DLL/TeamTalk.h" "$OUT/"
echo "$TAG $COMMIT ffmpeg" > "$ROOT/sdk/ios-src/.version"
ls -la "$OUT"
echo SDK-DONE

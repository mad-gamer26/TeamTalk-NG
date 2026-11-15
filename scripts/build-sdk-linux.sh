#!/bin/bash
# Builds BearWare's TeamTalk 5 SDK from source (v5.23, pinned) on Linux,
# in BearWare's own Docker images (Build/Docker), for:
#   linux               tt5srv and tt5prosrv (the encrypting server) and the
#                       libraries, into sdk/linux-src (for encryption tests)
#   android-arm64-v8a   the Android libraries (FFmpeg on, BearWare's
#   android-x64         default) into sdk/android-src/Library/TeamTalk_DLL/<abi>
#                       (not needed: BearWare's official Android SDK has
#                       FFmpeg; see docs/design.md)
# Google's WebRTC tools build Android only on Linux. No changes to
# BearWare's code. Slow the first time (WebRTC is fetched per platform).
#   scripts/build-sdk-linux.sh [linux] [android-arm64-v8a] [android-x64]
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=${TTNG_SDK_WORK:-$HOME/teamtalk-sdk-src-linux}
SRC=$WORK/src
TAG=v5.23
COMMIT=a0d26fdf90f447d39784641a9bc7be060373f534
# Half the machine at most: it's a server with other work to do.
CPUS=${TTNG_BUILD_CPUS:-4}
if [ ! -d "$SRC/.git" ]; then
    git clone -q --branch "$TAG" --depth 1 https://github.com/BearWare/TeamTalk5.git "$SRC"
    git -C "$SRC" submodule update --init --recursive --depth 1
fi
[ "$(git -C "$SRC" rev-parse HEAD)" = "$COMMIT" ] || { echo "$SRC isn't BearWare's $TAG ($COMMIT)" >&2; exit 1; }
mkdir -p "$WORK/home"
targets=("$@")
[ ${#targets[@]} -gt 0 ] || targets=(linux)

# Runs a build in BearWare's image; root inside (their Android image keeps
# the NDK in /root), and everything handed back to this user afterwards.
run() { # image dockerfile command
    docker build -q -t "$1" -f "$SRC/Build/Docker/$2" "$SRC/Build/Docker" >/dev/null
    docker run --rm --cpus "$CPUS" \
        -v "$SRC:/TeamTalk5" -v "$WORK/home:/work/home" -w /TeamTalk5 \
        -e HOME=/work/home -e MAKEFLAGS="-j$CPUS" \
        "$1" bash -c "trap 'chown -R $(id -u):$(id -g) /TeamTalk5 /work/home' EXIT; git config --global --add safe.directory '*'; set +u; source ./env.sh; set -u; $3"
}

for t in "${targets[@]}"; do
    echo "== $t"
    case "$t" in
        linux)
            run ttng-sdk-ubuntu24 Dockerfile_ubuntu24 \
                "make -C Build CMAKE_EXTRA='-DBUILD_TEAMTALK_CLIENTS=OFF -DBUILD_TEAMTALK_DOCUMENTATION=OFF' ubuntu24"
            OUT=$ROOT/sdk/linux-src
            mkdir -p "$OUT/Server" "$OUT/Library/TeamTalk_DLL"
            find "$SRC/Build/build-release-ubuntu24" "$SRC/Server" -type f \( -name tt5srv -o -name tt5prosrv \) -newer "$SRC/env.sh" -exec cp {} "$OUT/Server/" \; 2>/dev/null || true
            cp "$SRC"/Library/TeamTalk_DLL/libTeamTalk5*.so "$OUT/Library/TeamTalk_DLL/"
            cp "$SRC/Library/TeamTalk_DLL/TeamTalk.h" "$OUT/Library/TeamTalk_DLL/"
            ls -la "$OUT/Server" "$OUT/Library/TeamTalk_DLL"
            ;;
        android-arm64-v8a|android-x64)
            abi=${t#android-}; [ "$abi" = x64 ] && abi=x86_64
            run ttng-sdk-android Dockerfile_android "make -C Build $t"
            OUT=$ROOT/sdk/android-src/Library/TeamTalk_DLL
            mkdir -p "$OUT/$abi"
            cp "$SRC/Library/TeamTalk_DLL/$abi"/libTeamTalk5*.so "$OUT/$abi/"
            cp "$SRC/Library/TeamTalk_DLL/TeamTalk.h" "$OUT/"
            ls -la "$OUT/$abi"
            ;;
        *) echo "Unknown target $t" >&2; exit 2 ;;
    esac
done
for d in linux-src android-src; do [ -d "$ROOT/sdk/$d" ] && echo "$TAG $COMMIT ffmpeg" > "$ROOT/sdk/$d/.version"; done
echo SDK-DONE

#!/bin/sh
# Downloads BearWare's official TeamTalk 5 SDK for a platform into sdk/<name>/,
# checking it against the SHA-256 pinned here. The SDK isn't redistributed in
# this repository (its license); this is how a checkout gets it.
#
#   scripts/fetch-sdk.sh linux|android|ios|macos|windows [...]
#
# Needs curl and 7-Zip (7z, 7zz or 7za). Already fetched (same version): skipped.
set -eu

VERSION=5.23a
BASE=https://www.bearware.dk/teamtalksdk/v$VERSION
ROOT=$(cd "$(dirname "$0")/.." && pwd)

archive() {
    case "$1" in
        linux) echo "ubuntu26_x86_64 8372d358d34acf85c201106b1e7baf3773b632eb364e472f2d5ad6ce71060fc6" ;;
        android) echo "android 0fdc6a57705d91fd3ccc6a0505dfc8837bc27ba692a5483b71788bbf570270a7" ;;
        ios) echo "ios_universal 85bacadec9a1f7d069862950ecc83a008a4f4ea808f3f4dc1ba5c75ef53a91c5" ;;
        macos) echo "macos_universal 924d98521df56c4b19698a6855a52ff3903b4471a4bbce4f2e7dbe571ba06358" ;;
        windows) echo "win64 5b57da65f8a2b73156044678cf447967c4c96e1cc21dd44d06a2a57f8b84695f" ;;
        *) echo "Unknown platform: $1 (linux, android, ios, macos or windows)" >&2; exit 2 ;;
    esac
}

sha256() {
    if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

SEVENZIP=$(command -v 7z || command -v 7zz || command -v 7za || true)
[ -n "$SEVENZIP" ] || { echo "7-Zip isn't installed (7z, 7zz or 7za)." >&2; exit 1; }

[ $# -gt 0 ] || { echo "Usage: $0 linux|android|ios|macos|windows [...]" >&2; exit 2; }
for platform in "$@"; do
    set -- $(archive "$platform")
    name=$1 want=$2
    dest=$ROOT/sdk/$platform
    if [ -f "$dest/.version" ] && [ "$(cat "$dest/.version")" = "$VERSION $want" ]; then
        echo "$platform: SDK $VERSION already in sdk/$platform"
        continue
    fi
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    file=tt5sdk_v${VERSION}_$name.7z
    echo "$platform: downloading $file"
    curl -fsSL -o "$tmp/$file" "$BASE/$file"
    got=$(sha256 "$tmp/$file")
    if [ "$got" != "$want" ]; then
        echo "$platform: $file doesn't match its pinned SHA-256 (got $got); not used" >&2
        exit 1
    fi
    "$SEVENZIP" x -y -o"$tmp/x" "$tmp/$file" >/dev/null
    rm -rf "$dest"
    mkdir -p "$ROOT/sdk"
    mv "$tmp/x/tt5sdk_v${VERSION}_$name" "$dest"
    echo "$VERSION $want" > "$dest/.version"
    rm -rf "$tmp"
    trap - EXIT
    echo "$platform: SDK $VERSION in sdk/$platform"
done

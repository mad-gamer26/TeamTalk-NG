#!/bin/sh
# Publishes a signed release APK to ttmonitor.mad-gamer.com, where the app's
# updater finds it. Only the latest release is kept there.
#
#   ./publish.sh app/build/outputs/apk/release/app-release.apk "What's new."
#
# The version comes from output-metadata.json next to the APK. android.json goes
# last, so apps never see a half-published release.
set -e
HOST=matthew@ubuntu
DIR=/var/www/ttng-downloads
URL=https://ttmonitor.mad-gamer.com/downloads
APK="$1"
NOTES="${2:-}"
test -f "$APK" || { echo "usage: $0 app-release.apk [notes]"; exit 2; }
METADATA="$(dirname "$APK")/output-metadata.json"
test -f "$METADATA" || { echo "no output-metadata.json next to the APK"; exit 2; }
read_version() { python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['elements'][0]['$1'])" "$METADATA"; }
VERSION_NAME=$(read_version versionName)
VERSION_CODE=$(read_version versionCode)
# Each build gets its own file, so an app mid-download never sees it change.
NAME="teamtalk-ng-$VERSION_NAME-$VERSION_CODE.apk"
SHA256=$(shasum -a 256 "$APK" | cut -d' ' -f1)
SIZE=$(wc -c < "$APK" | tr -d ' ')
JSON=$(mktemp)
python3 - "$VERSION_NAME" "$VERSION_CODE" "$URL/$NAME" "$SHA256" "$SIZE" "$NOTES" > "$JSON" <<'PY'
import json, sys
name, code, url, sha, size, notes = sys.argv[1:]
print(json.dumps({"version_name": name, "version_code": int(code), "url": url,
                  "sha256": sha, "size": int(size), "notes": notes}, indent=2))
PY
scp -q "$APK" "$HOST:/tmp/$NAME"
scp -q "$JSON" "$HOST:/tmp/ttng-android.json"
rm "$JSON"
ssh "$HOST" "set -e
sudo mkdir -p $DIR
sudo mv /tmp/$NAME $DIR/$NAME
sudo mv /tmp/ttng-android.json $DIR/android.json
sudo find $DIR -maxdepth 1 -type f -name 'teamtalk-ng-*.apk' ! -name $NAME -delete
sudo chown -R www-data:www-data $DIR
sudo chmod 644 $DIR/*.apk $DIR/android.json"
echo "Published TeamTalk NG $VERSION_NAME (build $VERSION_CODE), sha256 $SHA256"

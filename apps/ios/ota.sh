#!/bin/sh
# Builds TeamTalk NG for an over-the-air install (the iPhone downloads it over
# Tailscale, for when it isn't on the Mac's network): archives, exports a
# development-signed ipa, and puts it with its manifest and an install page
# in ~/ttng-ota, served (tailnet only) at https://<this Mac>.ts.net by
#   python3 -m http.server 8767 --bind 127.0.0.1 --directory ~/ttng-ota
#   tailscale serve --bg --https=443 http://127.0.0.1:8767
# The build number is the time, so each install is an update.
#   apps/ios/ota.sh   (the login keychain must be unlocked)
set -eu
here=$(cd "$(dirname "$0")" && pwd)
out="${TTNG_OTA_DIR:-$HOME/ttng-ota}"
host="${TTNG_OTA_HOST:-$(/Applications/Tailscale.app/Contents/MacOS/Tailscale status --self --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))')}"
build=$(date +%Y%m%d%H%M)
cd "$here"
rm -rf build/ota && mkdir -p build/ota "$out"
xcodebuild -project TeamTalkNG.xcodeproj -scheme TeamTalkNG -configuration Release \
    -destination "generic/platform=iOS" -derivedDataPath build -archivePath build/ota/TeamTalkNG.xcarchive \
    -allowProvisioningUpdates CURRENT_PROJECT_VERSION="$build" archive | grep -E "error:|ARCHIVE" | sort -u
cat > build/ota/export.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>method</key><string>debugging</string>
<key>teamID</key><string>5NJK4F832Z</string>
<key>signingStyle</key><string>automatic</string>
<key>thinning</key><string>&lt;none&gt;</string>
</dict></plist>
PLIST
xcodebuild -exportArchive -archivePath build/ota/TeamTalkNG.xcarchive -exportPath build/ota/export \
    -exportOptionsPlist build/ota/export.plist -allowProvisioningUpdates | grep -E "error:|EXPORT" | sort -u
app=build/ota/TeamTalkNG.xcarchive/Products/Applications/TeamTalkNG.app
id=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$app/Info.plist")
version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$app/Info.plist")
cp build/ota/export/TeamTalkNG.ipa "$out/TeamTalkNG.ipa"
cat > "$out/manifest.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>items</key><array><dict>
<key>assets</key><array><dict><key>kind</key><string>software-package</string><key>url</key><string>https://$host/TeamTalkNG.ipa?b=$build</string></dict></array>
<key>metadata</key><dict><key>bundle-identifier</key><string>$id</string><key>bundle-version</key><string>$version</string><key>kind</key><string>software</string><key>title</key><string>TeamTalk NG</string></dict>
</dict></array></dict></plist>
PLIST
cat > "$out/index.html" <<HTML
<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Install TeamTalk NG</title></head>
<body><main><h1>TeamTalk NG</h1><p>Build $build.</p>
<p><a href="itms-services://?action=download-manifest&amp;url=https://$host/manifest.plist?b=$build">Install TeamTalk NG</a></p>
<p>After tapping, confirm Install. It replaces the TeamTalk NG you have, keeping its settings.</p></main></body></html>
HTML
echo "Build $build ready at https://$host"

#!/bin/sh
# Compile TeamTalk NG's monitor code for Mac Catalyst into tests/app_check/build/harness.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
app="$here/../../../Client/iTeamTalk/iTeamTalk/Monitor"
mkdir -p "$here/build"
rm -f "$here/build/harness"
sdk=$(xcrun --show-sdk-path --sdk macosx)
xcrun swiftc -target arm64-apple-ios17.0-macabi -sdk "$sdk" \
    -Fsystem "$sdk/System/iOSSupport/System/Library/Frameworks" \
    -I "$sdk/System/iOSSupport/usr/lib/swift" -L "$sdk/System/iOSSupport/usr/lib/swift" -L /usr/lib/swift \
    -swift-version 5 -parse-as-library -o "$here/build/harness" \
    "$app/MonitorShared.swift" "$app/MonitorModels.swift" "$app/MonitorClient.swift" "$app/MonitorNotifications.swift" \
    "$app/MonitorEvents.swift" "$here/stubs.swift" "$here/main.swift"
echo "Built $here/build/harness"

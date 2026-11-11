#!/bin/zsh
set -euo pipefail
cd -- "${0:A:h}"
airpointer_build_mode="${AIRPOINTER_OPTIMIZATION:--O}"
airpointer_signing_identity="${AIRPOINTER_SIGNING_IDENTITY:--}"
# 根据实际 SDK 启用新 API, 运行时版本检查仍由 Swift 代码负责.
airpointer_sdk_version="$(xcrun --sdk macosx --show-sdk-version)"
airpointer_swift_flags=()
if (( ${airpointer_sdk_version%%.*} >= 27 )); then
    airpointer_swift_flags+=(-D AIRPOINTER_MACOS27_SDK)
fi
# Compile first, so a failed build leaves the last good app as it was.
compiled="$(mktemp -d)"
trap 'rm -rf "$compiled"' EXIT
clang -fobjc-arc -Wall -Wextra -Werror -framework Foundation -framework CoreBluetooth -framework IOBluetooth -framework CoreMotion Sources/ClosedCaseMotion/CaseSustainedRenewal.m -o "$compiled/ClosedCaseMotion.bin"
xcrun swiftc -swift-version 5 -O Sources/ClosedCaseRestore/ClosedCaseRestore.swift -o "$compiled/ClosedCaseRestore.bin" -framework Foundation -framework CoreBluetooth -framework IOBluetooth
xcrun swiftc -swift-version 5 "$airpointer_build_mode" "${airpointer_swift_flags[@]}" Sources/AirPointer/**/*.swift -o "$compiled/AirPointer" -framework AppKit -framework JavaScriptCore -framework QuartzCore -framework ApplicationServices -framework Carbon -framework AVFoundation -framework CoreAudio -framework CoreBluetooth
mkdir -p AirPointer.app/Contents/MacOS AirPointer.app/Contents/Resources
cp Assets/CaseFront.png Assets/AppIcon.icns AirPointer.app/Contents/Resources/
for frame in Assets/CaseLid/lid-*.png; do cp "$frame" "AirPointer.app/Contents/Resources/Case${frame:t:r:s/lid/Lid/}.png"; done
cp Assets/TapClick/click.wav AirPointer.app/Contents/Resources/TapClick.wav
cp Assets/NotchShimmer.wav AirPointer.app/Contents/Resources/NotchShimmer.wav
cp Assets/TapClick/LICENSE-cuelume.txt AirPointer.app/Contents/Resources/LICENSE-cuelume.txt
cp Sources/AirPointer/Session/Orientation.js AirPointer.app/Contents/Resources/ClosedCaseOrientation.js
mv -f "$compiled/ClosedCaseMotion.bin" "$compiled/ClosedCaseRestore.bin" AirPointer.app/Contents/Resources/
# The app finds the paired AirPods itself; no address is built in.
cat > AirPointer.app/Contents/Info.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>AirPointer</string>
<key>CFBundleIdentifier</key><string>local.airpointer</string>
<key>CFBundleName</key><string>AirPointer</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.2</string>
<key>CFBundleVersion</key><string>2</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSBluetoothAlwaysUsageDescription</key><string>AirPointer connects to your paired AirPods to keep motion available with the case closed.</string>
<key>NSMotionUsageDescription</key><string>AirPointer reads motion from your AirPods Pro 1 to move the pointer and detect taps.</string>
</dict></plist>
PLIST
mv -f "$compiled/AirPointer" AirPointer.app/Contents/MacOS/AirPointer
if [[ "$airpointer_signing_identity" != "-" ]]; then
    codesign --force --sign "$airpointer_signing_identity" --timestamp=none --identifier local.airpointer.closed-case-motion AirPointer.app/Contents/Resources/ClosedCaseMotion.bin
    codesign --force --sign "$airpointer_signing_identity" --timestamp=none --identifier local.airpointer.closed-case-restore AirPointer.app/Contents/Resources/ClosedCaseRestore.bin
fi
codesign --force --sign "$airpointer_signing_identity" --timestamp=none AirPointer.app
/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -f "$PWD/AirPointer.app"
AirPointer.app/Contents/MacOS/AirPointer --self-test
AirPointer.app/Contents/MacOS/AirPointer --check-closed-case-tap Tests/TapFixtures.csv

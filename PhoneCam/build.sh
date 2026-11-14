#!/bin/sh
# Builds PhoneCam.ipa for iPhone 4S (armv7, iOS 9) with today's command-line tools.
# Install the result with Sideloadly (free Apple ID) or, on a jailbroken phone, via AppSync.
set -e
cd "$(dirname "$0")"
[ -d .sdk/iPhoneOS9.3.sdk ] || ./get-sdk.sh
SDK=.sdk/iPhoneOS9.3.sdk
APP=build/Payload/PhoneCam.app
rm -rf build && mkdir -p "$APP"

# Compile and link separately: with -fobjc-arc at link time and an iOS 8 target, clang insists on
# libarclite, which today's tools no longer ship (and iOS 8 doesn't need).
# -mno-thumb: the linker in Xcode's October 2026 update (ld-27106) stopped flagging a Thumb main() in the
# app's entry point, so iOS 9 started it in ARM mode and the app died on launch with SIGILL. Plain ARM code
# has no such flag to lose.
clang -target armv7-apple-ios8.0 -isysroot "$SDK" -fobjc-arc -Os -mno-thumb -Wall -Wno-deprecated-declarations -c main.m -o build/main.o
clang -target armv7-apple-ios8.0 -isysroot "$SDK" build/main.o -o "$APP/PhoneCam" \
  -framework UIKit -framework Foundation -framework AVFoundation -framework CoreMedia -framework CoreVideo \
  -framework AudioToolbox -framework ImageIO -framework MobileCoreServices -framework CoreGraphics -framework CFNetwork

# Bake in this Mac's PhoneDeck address so the app connects on first launch (editable via SET).
IP=$(ipconfig getifaddr en0 || ipconfig getifaddr en1 || echo 192.168.0.2)
TOKEN=$(cat ~/.phonedeck/token 2>/dev/null || echo "")
sed "s|__PHONEDECK_URL__|http://$IP:8045/#k=$TOKEN|" Info.plist > "$APP/Info.plist"
plutil -convert binary1 "$APP/Info.plist"
printf 'APPL????' > "$APP/PkgInfo"
swift make-assets.swift "$APP" 2>/dev/null
(cd build && zip -qry PhoneCam.ipa Payload)
echo "Built $(pwd)/build/PhoneCam.ipa  (connects to http://$IP:8045)"

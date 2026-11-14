#!/bin/sh
# Fetches the iOS 9.3 SDK from github.com/theos/sdks and patches it so today's Apple linker
# accepts it for armv7: drop the Intel archs (otherwise ld treats the stubs as Simulator-only)
# and add an empty liblaunch stub that the old libSystem re-exports.
set -e
cd "$(dirname "$0")"
[ -d .sdk/iPhoneOS9.3.sdk ] && { echo "SDK already at .sdk/iPhoneOS9.3.sdk"; exit 0; }
tmp=$(mktemp -d)
git clone -q --depth 1 --filter=blob:none --sparse https://github.com/theos/sdks.git "$tmp/sdks"
git -C "$tmp/sdks" sparse-checkout set iPhoneOS9.3.sdk
mkdir -p .sdk && mv "$tmp/sdks/iPhoneOS9.3.sdk" .sdk/ && rm -rf "$tmp"
find .sdk -name '*.tbd' -print0 | xargs -0 perl -pi -e 's/,\s*(i386|x86_64)\b//g; s/\b(i386|x86_64)\s*,\s*//g'
cat > .sdk/iPhoneOS9.3.sdk/usr/lib/system/liblaunch.tbd <<'TBD'
---
archs: [ armv7, armv7s, arm64 ]
platform: ios
install-name: /usr/lib/system/liblaunch.dylib
current-version: 1
compatibility-version: 1
exports:
  - archs: [ armv7, armv7s, arm64 ]
    symbols: [ ___phonedeck_liblaunch_stub ]
...
TBD
echo "SDK ready at .sdk/iPhoneOS9.3.sdk"

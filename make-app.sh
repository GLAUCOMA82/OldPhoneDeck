#!/bin/sh
# Builds PhoneDeck.app: the same server, launched as its own (menu bar) app so macOS
# privacy prompts (Calendar, Automation, Accessibility) are asked for PhoneDeck itself.
set -e
cd "$(dirname "$0")"
swift build -c release
# Rebuild in place if PhoneDeck was moved to /Applications.
APP=PhoneDeck.app
[ -d /Applications/PhoneDeck.app ] && APP=/Applications/PhoneDeck.app
rm -rf "$APP" && mkdir -p "$APP/Contents/MacOS"
BIN="$(swift build -c release --show-bin-path)"
cp "$BIN/phonedeck" "$APP/Contents/MacOS/phonedeck"
# Give the executable a fixed Mach-O UUID: macOS's Local Network privacy identifies apps by it, so a new UUID
# on every build silently revokes the iPhone/iPad connection permission. (Codesigning below re-hashes the file.)
python3 - "$APP/Contents/MacOS/phonedeck" <<'PY'
import hashlib, struct, sys
path = sys.argv[1]; data = bytearray(open(path, 'rb').read())
fixed = hashlib.md5(b'com.phonedeck.server').digest()
def patch(base):
    magic = struct.unpack_from('<I', data, base)[0]
    if magic != 0xfeedfacf: return 0
    ncmds = struct.unpack_from('<I', data, base + 16)[0]; off = base + 32; n = 0
    for _ in range(ncmds):
        cmd, size = struct.unpack_from('<II', data, off)
        if cmd == 0x1b: data[off + 8:off + 24] = fixed; n += 1
        off += size
    return n
done = 0
if struct.unpack_from('>I', data, 0)[0] == 0xcafebabe:            # universal binary
    for i in range(struct.unpack_from('>I', data, 4)[0]):
        done += patch(struct.unpack_from('>I', data, 8 + i * 20 + 8)[0])
else:
    done = patch(0)
open(path, 'wb').write(data)
print('fixed UUID in %d slice(s)' % done)
PY
# The web files stay in the build folder (linked, not copied): `swift build -c release` updates the
# deck and Command Center without changing the app's signature, so macOS keeps its permissions.
mkdir -p "$APP/Contents/Resources"
ln -s "$BIN/PhoneDeck_phonedeck.bundle" "$APP/Contents/Resources/PhoneDeck_phonedeck.bundle"
cp PhoneDeck.icns "$APP/Contents/Resources/PhoneDeck.icns"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.phonedeck.server</string>
  <key>CFBundleName</key><string>PhoneDeck</string>
  <key>CFBundleExecutable</key><string>phonedeck</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.1</string>
  <key>CFBundleIconFile</key><string>PhoneDeck</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSLocalNetworkUsageDescription</key><string>Lets your iPhone and iPad decks connect to PhoneDeck on this Mac over Wi-Fi.</string>
  <key>NSBonjourServices</key><array><string>_phonedeck._tcp</string></array>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
  <key>NSCalendarsFullAccessUsageDescription</key><string>Shows your upcoming events on the PhoneDeck dashboard.</string>
  <key>NSAppleEventsUsageDescription</key><string>Reads now playing and toggles dark mode for the PhoneDeck dashboard.</string>
</dict></plist>
PLIST
# Sign with a stable local identity (self-signed, kept in its own keychain file under ~/.phonedeck).
# macOS ties Accessibility / Full Disk Access to the signature: an ad-hoc signature changes with every
# build and loses them, a fixed certificate keeps them across rebuilds. Nothing is added to your login keychain.
KC="$HOME/.phonedeck/signing.keychain-db"; KCPW="phonedeck-local-signing"; ID="PhoneDeck Local Signing"
# Use macOS's own openssl (LibreSSL): OpenSSL 3 from Homebrew or conda writes .p12 files with an encryption
# that `security import` rejects ("MAC verification failed").
OPENSSL=/usr/bin/openssl
# A run that failed halfway leaves a keychain without the identity: start that one over.
# (No -v: a self-signed identity is never "valid" (trusted), but codesign uses it fine.)
if [ -f "$KC" ] && ! security find-identity -p codesigning "$KC" 2>/dev/null | grep -q "\"$ID\""; then
  echo "Signing keychain has no \"$ID\" identity; recreating it"
  security delete-keychain "$KC" 2>/dev/null || rm -f "$KC"
fi
if [ ! -f "$KC" ]; then
  mkdir -p "$HOME/.phonedeck"
  T="$(mktemp -d)"
  cat > "$T/cert.cnf" <<'CNF'
[req]
distinguished_name = dn
prompt = no
[dn]
CN = PhoneDeck Local Signing
[ext]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
CNF
  "$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$T/cert.cnf" -extensions ext -keyout "$T/key.pem" -out "$T/cert.pem" 2>/dev/null
  "$OPENSSL" pkcs12 -export -inkey "$T/key.pem" -in "$T/cert.pem" -name "$ID" -out "$T/id.p12" -passout pass:"$KCPW" 2>/dev/null
  security create-keychain -p "$KCPW" "$KC"
  security set-keychain-settings "$KC"
  security unlock-keychain -p "$KCPW" "$KC"
  security import "$T/id.p12" -k "$KC" -P "$KCPW" -T /usr/bin/codesign >/dev/null
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KCPW" "$KC" >/dev/null
  rm -rf "$T"
fi
security unlock-keychain -p "$KCPW" "$KC"
codesign --force --keychain "$KC" -s "$ID" "$APP"
echo "Built $APP"

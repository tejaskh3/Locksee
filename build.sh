#!/bin/bash
# Builds Locker.app — a native macOS menu bar screen locker.
set -euo pipefail
cd "$(dirname "$0")"

APP="Locker.app"
NAME="Locker"

echo "→ Compiling…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

swiftc -O -o "$APP/Contents/MacOS/$NAME" Sources/main.swift \
    -framework Cocoa -framework LocalAuthentication -framework IOKit \
    -framework ServiceManagement

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$NAME</string>
    <key>CFBundleDisplayName</key><string>Locker</string>
    <key>CFBundleIdentifier</key><string>com.tejas.locker</string>
    <key>CFBundleVersion</key><string>1.0</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleExecutable</key><string>$NAME</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Sign so Touch ID / password auth works and Gatekeeper stays quiet.
#
# Prefer a stable self-signed identity. An ad-hoc signature (--sign -) has no
# certificate, so its designated requirement is a hash of the exact binary —
# every rebuild produces a new hash, which silently invalidates the app's
# Accessibility grant while System Settings still shows the toggle as ON.
# Signing with a real identity keys the requirement to the certificate instead,
# so the grant survives rebuilds.
SIGN_ID="${LOCKER_SIGN_ID:-Locker Dev}"

# Note: no -v. The identity is a self-signed root, so it reports as untrusted
# (CSSMERR_TP_NOT_TRUSTED) and -v would hide it — but codesign signs with it
# fine. Trust only matters for Gatekeeper on downloaded apps.
if security find-identity -p codesigning | grep -qF "$SIGN_ID"; then
    codesign --force --sign "$SIGN_ID" "$APP"
    echo "✓ Signed with '$SIGN_ID'"
else
    codesign --force --sign - "$APP"
    echo "⚠️  No '$SIGN_ID' identity found — fell back to an ad-hoc signature."
    echo "   Accessibility permission will break on every rebuild. To fix once:"
    echo "   Keychain Access ▸ Certificate Assistant ▸ Create a Certificate…"
    echo "   name '$SIGN_ID', type 'Code Signing', self-signed."
fi

echo "✓ Built $APP"
echo "  Run it with:  open $APP"

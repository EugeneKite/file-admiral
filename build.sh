#!/bin/bash
# Builds FileAdmiral.app into ./build
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP=build/FileAdmiral.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/FileAdmiral "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"

if [ ! -f Resources/AppIcon.icns ] || [ Resources/IconArtwork.png -nt Resources/AppIcon.icns ]; then
    rm -rf build/AppIcon.iconset
    if [ -f Resources/IconArtwork.png ]; then
        swift Tools/IconFromImage.swift Resources/IconArtwork.png build/AppIcon.iconset
    else
        swift Tools/MakeIcon.swift build/AppIcon.iconset
    fi
    iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/"

# Sign with a stable local identity. An ad-hoc signature changes with every build, which makes
# macOS forget privacy permissions (Full Disk Access, folder access) after each rebuild.
# The identity lives in its own keychain that is not added to the keychain search list.
SIGN_DIR="$HOME/Library/Application Support/FileAdmiral/signing"
KEYCHAIN="$SIGN_DIR/signing.keychain-db"
KEYCHAIN_PASS="fileadmiral-local"
IDENTITY="FileAdmiral Local Signing"

has_identity() {
    [ -f "$KEYCHAIN" ] &&
        security unlock-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN" 2>/dev/null &&
        security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "$IDENTITY"
}

if ! has_identity; then
    echo "Creating local signing identity in $KEYCHAIN"
    # A keychain left behind by an interrupted setup is recreated.
    if [ -f "$KEYCHAIN" ]; then security delete-keychain "$KEYCHAIN" 2>/dev/null || rm -f "$KEYCHAIN"; fi
    mkdir -p "$SIGN_DIR"
    TMP=$(mktemp -d)
    trap 'rm -rf "$TMP"' EXIT
    cat > "$TMP/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $IDENTITY
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF
    # The system LibreSSL: Homebrew/conda OpenSSL 3 write PKCS#12 files that `security import` rejects.
    /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -days 7300 \
        -config "$TMP/cert.cnf" 2>/dev/null
    /usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/id.p12" -passout pass:"$KEYCHAIN_PASS"
    security create-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN"
    security set-keychain-settings "$KEYCHAIN"
    security unlock-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN"
    security import "$TMP/id.p12" -k "$KEYCHAIN" -P "$KEYCHAIN_PASS" -T /usr/bin/codesign >/dev/null
    security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PASS" "$KEYCHAIN" >/dev/null
    rm -rf "$TMP"
    trap - EXIT
fi
security unlock-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN"
codesign --force --keychain "$KEYCHAIN" --sign "$IDENTITY" "$APP"

echo "Built $APP"

#!/bin/bash
# Builds Amaranth as a proper macOS .app bundle. Signs with a stable
# code-signing identity (the user's Apple Development cert, or any single
# identity that's present in their login keychain) so TCC entries for
# Bluetooth permission persist across rebuilds.
set -euo pipefail

cd "$(dirname "$0")"

CONFIG="${1:-debug}"
case "$CONFIG" in
    debug|release) ;;
    *) echo "usage: $0 [debug|release]" >&2; exit 2 ;;
esac

# Pick a stable signing identity. Prefer Apple Development if present,
# otherwise the first available code-signing identity, otherwise ad-hoc.
choose_identity() {
    local devid
    devid=$(security find-identity -v -p codesigning 2>/dev/null \
            | awk -F'"' '/Apple Development/ {print $2; exit}')
    if [ -n "$devid" ]; then
        echo "$devid"
        return
    fi
    local any
    any=$(security find-identity -v -p codesigning 2>/dev/null \
          | awk -F'"' '/^\s+[0-9]+\)/ {print $2; exit}')
    if [ -n "$any" ]; then
        echo "$any"
        return
    fi
    echo "-"
}

SIGN_IDENT=$(choose_identity)

echo "→ swift build -c $CONFIG"
swift build -c "$CONFIG"

BIN_PATH=$(swift build -c "$CONFIG" --show-bin-path)
APP_BUNDLE="$BIN_PATH/Amaranth.app"
echo "→ assembling $APP_BUNDLE"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BIN_PATH/Amaranth" "$APP_BUNDLE/Contents/MacOS/Amaranth"
cp Info.plist "$APP_BUNDLE/Contents/Info.plist"

for bundle in "$BIN_PATH"/*.bundle; do
    [ -d "$bundle" ] || continue
    cp -R "$bundle" "$APP_BUNDLE/Contents/Resources/" 2>/dev/null || true
done

echo "→ codesign with: $SIGN_IDENT"
codesign --force --deep --sign "$SIGN_IDENT" "$APP_BUNDLE"

echo
echo "Built: $APP_BUNDLE"
echo "Run:   open '$APP_BUNDLE'"

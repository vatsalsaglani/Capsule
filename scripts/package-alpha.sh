#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
VERSION="${1:-v$(<"$ROOT/VERSION")}"
OUTPUT="${2:-$ROOT/dist}"
DERIVED_DATA="${CAPSULE_DERIVED_DATA:-$ROOT/.build/app-release}"
PRODUCT_VERSION="${VERSION#v}"
MARKETING_VERSION="${PRODUCT_VERSION%%-*}"

if [[ "$OUTPUT" != /* ]]; then
  OUTPUT="$ROOT/$OUTPUT"
fi

mkdir -p "$OUTPUT"
rm -rf "$OUTPUT/Capsule.app"
rm -f "$OUTPUT/Capsule-$VERSION.app.zip" \
  "$OUTPUT/Capsule-$VERSION.dmg" \
  "$OUTPUT/capsule-$VERSION-arm64-apple-macos.tar.gz" \
  "$OUTPUT/checksums.txt"

cd "$ROOT"

swift build -c release --product capsule
BIN_DIR="$(swift build -c release --product capsule --show-bin-path)"
tar -C "$BIN_DIR" -czf "$OUTPUT/capsule-$VERSION-arm64-apple-macos.tar.gz" capsule

xcodegen generate --spec App/project.yml --project App
xcodebuild \
  -project App/Capsule.xcodeproj \
  -scheme Capsule \
  -configuration Release \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  build

APP="$(find "$DERIVED_DATA/Build/Products" -maxdepth 2 -name Capsule.app -type d | head -1)"
test -n "$APP"
test -x "$APP/Contents/Helpers/capsule"
test "$("$APP/Contents/Helpers/capsule" --version)" = "$PRODUCT_VERSION"
test "$(plutil -extract CapsuleReleaseVersion raw "$APP/Contents/Info.plist")" = "$PRODUCT_VERSION"
test "$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")" = "$MARKETING_VERSION"
"$APP/Contents/Helpers/capsule" --help >/dev/null

# This is deliberately an ad-hoc developer signature, not notarization.
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
ditto "$APP" "$OUTPUT/Capsule.app"
ditto -c -k --sequesterRsrc --keepParent "$OUTPUT/Capsule.app" "$OUTPUT/Capsule-$VERSION.app.zip"

STAGING="$(mktemp -d "${TMPDIR:-/tmp}/capsule-dmg.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
ditto "$OUTPUT/Capsule.app" "$STAGING/Capsule.app"
ln -s /Applications "$STAGING/Applications"
hdiutil create \
  -volname "Capsule $VERSION" \
  -srcfolder "$STAGING" \
  -ov \
  -format UDZO \
  "$OUTPUT/Capsule-$VERSION.dmg"

cd "$OUTPUT"
shasum -a 256 \
  "Capsule-$VERSION.app.zip" \
  "Capsule-$VERSION.dmg" \
  "capsule-$VERSION-arm64-apple-macos.tar.gz" \
  > checksums.txt

echo "Alpha artifacts written to $OUTPUT"

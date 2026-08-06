#!/usr/bin/env bash
# Manual fallback for release-native.yml — same artifacts, same invariants.
# Requires: xcodegen, jq, npx, python3, and the two signing keys:
#   TAURI_SIGNING_PRIVATE_KEY_PATH (default ~/.tauri/tokcat.key)  [minisign]
#   SPARKLE_PRIVATE_KEY_PATH (default ~/.tauri/tokcat-sparkle-ed25519.key)
#
# Contract: versions must already be bumped and committed (native/project.yml
# MARKETING_VERSION + CURRENT_PROJECT_VERSION), and the git tag v<version>
# must exist. Every release MUST ship all five assets — see the gate below.
set -euo pipefail

cd "$(dirname "$0")/.."
VERSION="$(grep -E '^\s*MARKETING_VERSION:' native/project.yml | awk '{print $2}')"
BUILD_NUM="$(grep -E '^\s*CURRENT_PROJECT_VERSION:' native/project.yml | awk '{print $2}')"
TAG="v${VERSION}"
REPO="handlecusion/tokcat"
BASE="https://github.com/${REPO}/releases/download/${TAG}"
OUT="release-native-out"
TAURI_KEY="${TAURI_SIGNING_PRIVATE_KEY_PATH:-$HOME/.tauri/tokcat.key}"
SPARKLE_KEY="${SPARKLE_PRIVATE_KEY_PATH:-$HOME/.tauri/tokcat-sparkle-ed25519.key}"

git rev-parse "$TAG" >/dev/null 2>&1 || { echo "tag $TAG missing"; exit 1; }
[ -f "$TAURI_KEY" ] || { echo "minisign key missing: $TAURI_KEY"; exit 1; }
[ -f "$SPARKLE_KEY" ] || { echo "sparkle key missing: $SPARKLE_KEY"; exit 1; }

rm -rf "$OUT" && mkdir -p "$OUT"

echo "==> Build universal (v$VERSION, build $BUILD_NUM)"
(cd native && xcodegen generate && xcodebuild -project Tokcat.xcodeproj \
  -scheme Tokcat -configuration Release -destination 'platform=macOS' \
  -derivedDataPath build-release \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO CODE_SIGN_IDENTITY="-" build)
APP="native/build-release/Build/Products/Release/Tokcat.app"
lipo -archs "$APP/Contents/MacOS/tokcat" | tr ' ' '\n' | sort | tr '\n' ' ' | grep -q "arm64 x86_64"
codesign --force --deep -s - "$APP"
codesign --verify --deep --strict "$APP"

ASSET="Tokcat_${VERSION}_universal.app.tar.gz"
tar -C "$(dirname "$APP")" -czf "$OUT/$ASSET" Tokcat.app
tar -tzf "$OUT/$ASSET" | grep -q "Sparkle.framework/Versions" \
  || { echo "Sparkle symlinks missing from tarball"; exit 1; }

echo "==> DMG"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Tokcat" -srcfolder "$STAGE" -ov -format UDZO \
  -imagekey zlib-level=9 "$OUT/Tokcat_${VERSION}_universal.dmg"
shasum -a 256 "$OUT/Tokcat_${VERSION}_universal.dmg" | awk '{print $1}' \
  > "$OUT/Tokcat_${VERSION}_universal.dmg.sha256"

echo "==> Sign (minisign, legacy Tauri channel)"
npx --yes @tauri-apps/cli signer sign -f "$TAURI_KEY" \
  ${TAURI_SIGNING_PRIVATE_KEY_PASSWORD:+-p "$TAURI_SIGNING_PRIVATE_KEY_PASSWORD"} \
  "$OUT/$ASSET"
test -s "$OUT/$ASSET.sig"

echo "==> Sign (Sparkle EdDSA)"
SPARKLE_DIST="$OUT/sparkle-dist"
mkdir -p "$SPARKLE_DIST"
curl -sSfL -o "$OUT/sparkle.tar.xz" \
  "https://github.com/sparkle-project/Sparkle/releases/download/2.6.4/Sparkle-2.6.4.tar.xz"
tar -xf "$OUT/sparkle.tar.xz" -C "$SPARKLE_DIST" bin/sign_update
"$SPARKLE_DIST/bin/sign_update" --ed-key-file "$SPARKLE_KEY" "$OUT/$ASSET" \
  > "$OUT/ed-signature.txt"
ED_SIG="$(sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' "$OUT/ed-signature.txt")"
LENGTH="$(sed -n 's/.*length="\([^"]*\)".*/\1/p' "$OUT/ed-signature.txt")"

echo "==> Manifests"
NOTES_FILE="$OUT/release-notes.md"
git tag -l --format='%(contents)' "$TAG" > "$NOTES_FILE"
[ -s "$NOTES_FILE" ] || echo "Tokcat ${VERSION}" > "$NOTES_FILE"

jq -n \
  --arg version "$VERSION" \
  --arg notes "$(cat "$NOTES_FILE")" \
  --arg pub_date "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg sig "$(cat "$OUT/$ASSET.sig")" \
  --arg url "$BASE/$ASSET" \
  '{version:$version, notes:$notes, pub_date:$pub_date,
    platforms:{"darwin-aarch64":{signature:$sig,url:$url},
               "darwin-x86_64":{signature:$sig,url:$url}}}' \
  > "$OUT/latest.json"

python3 scripts/make_appcast.py --version "$VERSION" --build "$BUILD_NUM" \
  --url "$BASE/$ASSET" --ed-signature "$ED_SIG" --length "$LENGTH" \
  --notes-file "$NOTES_FILE" > "$OUT/appcast.xml"

echo "==> Asset gate"
for f in "Tokcat_${VERSION}_universal.dmg" "$ASSET" "$ASSET.sig" latest.json appcast.xml; do
  [ -s "$OUT/$f" ] || { echo "MISSING RELEASE ASSET: $f"; exit 1; }
done

echo "==> Publish"
gh release create "$TAG" \
  "$OUT/Tokcat_${VERSION}_universal.dmg" \
  "$OUT/Tokcat_${VERSION}_universal.dmg.sha256" \
  "$OUT/$ASSET" "$OUT/$ASSET.sig" \
  "$OUT/latest.json" "$OUT/appcast.xml" \
  --repo "$REPO" --title "Tokcat $VERSION" --notes-file "$NOTES_FILE"

echo
echo "Done. Remember: the Homebrew tap is updated by CI; for a manual release"
echo "update handlecusion/homebrew-tokcat/Casks/tokcat.rb yourself."

#!/usr/bin/env bash
# Build, sign, and publish a Tokcat release.
#
# Usage:
#   scripts/release.sh <version> "<release notes>"
#
# Example:
#   scripts/release.sh 0.1.3 "Add auto-update support."
#
# Prerequisites:
#   - gh CLI authenticated for handlecusion/tokcat
#   - Updater private key at ~/.tauri/tokcat.key
#   - package.json / Cargo.toml / tauri.conf.json already bumped to <version>
#     and committed on main.

set -euo pipefail

VERSION="${1:-}"
NOTES="${2:-}"

if [[ -z "$VERSION" || -z "$NOTES" ]]; then
  echo "usage: $0 <version> <notes>" >&2
  exit 1
fi

KEY_PATH="${TAURI_SIGNING_PRIVATE_KEY_PATH:-$HOME/.tauri/tokcat.key}"
if [[ ! -f "$KEY_PATH" ]]; then
  echo "signing key not found at $KEY_PATH" >&2
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

# Ensure version files match the requested version.
PKG_VER="$(node -p "require('./package.json').version")"
CARGO_VER="$(grep -E '^version = ' src-tauri/Cargo.toml | head -1 | sed -E 's/version = "([^"]+)"/\1/')"
TAURI_VER="$(node -p "require('./src-tauri/tauri.conf.json').version")"
if [[ "$PKG_VER" != "$VERSION" || "$CARGO_VER" != "$VERSION" || "$TAURI_VER" != "$VERSION" ]]; then
  echo "version mismatch: expected $VERSION package.json=$PKG_VER Cargo.toml=$CARGO_VER tauri.conf.json=$TAURI_VER" >&2
  exit 1
fi

TAG="v$VERSION"
DOWNLOAD_BASE="https://github.com/handlecusion/tokcat/releases/download/$TAG"
RELEASE_DIR="src-tauri/target/release-artifacts"
LATEST_JSON="$RELEASE_DIR/latest.json"

strip_volume_icon() {
  local dmg="$1"
  echo "==> Stripping .VolumeIcon.icns from $dmg"
  local dmg_rw="${dmg%.dmg}.rw.dmg"
  local dmg_mnt
  dmg_mnt="$(mktemp -d)"
  hdiutil convert "$dmg" -format UDRW -o "$dmg_rw" -ov >/dev/null
  hdiutil attach -nobrowse -mountpoint "$dmg_mnt" "$dmg_rw" >/dev/null
  rm -f "$dmg_mnt/.VolumeIcon.icns"
  SetFile -a c "$dmg_mnt" 2>/dev/null || true
  hdiutil detach "$dmg_mnt" >/dev/null
  rmdir "$dmg_mnt" 2>/dev/null || true
  hdiutil convert "$dmg_rw" -format UDZO -imagekey zlib-level=9 -o "$dmg" -ov >/dev/null
  rm -f "$dmg_rw"
}

build_arch() {
  local rust_target="$1"
  local platform_key="$2"
  local asset_arch="$3"

  echo "==> Building $rust_target"
  rustup target add "$rust_target"
  TAURI_SIGNING_PRIVATE_KEY="$(cat "$KEY_PATH")" \
    TAURI_SIGNING_PRIVATE_KEY_PASSWORD="${TAURI_SIGNING_PRIVATE_KEY_PASSWORD:-}" \
    pnpm tauri build --target "$rust_target"

  local bundle_dir="src-tauri/target/${rust_target}/release/bundle"
  local dmg
  dmg="$(find "$bundle_dir/dmg" -maxdepth 1 -type f -name "Tokcat_${VERSION}_*.dmg" -print -quit)"
  local app_tgz="$bundle_dir/macos/Tokcat.app.tar.gz"
  local app_sig="$bundle_dir/macos/Tokcat.app.tar.gz.sig"
  for f in "$dmg" "$app_tgz" "$app_sig"; do
    if [[ ! -f "$f" ]]; then
      echo "expected artifact missing: $f" >&2
      exit 1
    fi
  done

  strip_volume_icon "$dmg"

  mkdir -p "$RELEASE_DIR"
  cp "$dmg" "$RELEASE_DIR/Tokcat_${VERSION}_${asset_arch}.dmg"
  cp "$app_tgz" "$RELEASE_DIR/Tokcat_${VERSION}_${asset_arch}.app.tar.gz"
  cp "$app_sig" "$RELEASE_DIR/Tokcat_${VERSION}_${asset_arch}.app.tar.gz.sig"
  shasum -a 256 "$RELEASE_DIR/Tokcat_${VERSION}_${asset_arch}.dmg" > "$RELEASE_DIR/${platform_key}.dmg.sha256"
}

echo "==> Building release with updater artifacts"
mkdir -p "$RELEASE_DIR"
find "$RELEASE_DIR" -mindepth 1 -maxdepth 1 -exec rm -R {} +
build_arch "aarch64-apple-darwin" "darwin-aarch64" "aarch64"
build_arch "x86_64-apple-darwin" "darwin-x86_64" "x64"

ARM_SIG="$(cat "$RELEASE_DIR/Tokcat_${VERSION}_aarch64.app.tar.gz.sig")"
INTEL_SIG="$(cat "$RELEASE_DIR/Tokcat_${VERSION}_x64.app.tar.gz.sig")"
SHA256_ARM="$(awk '{print $1}' "$RELEASE_DIR/darwin-aarch64.dmg.sha256")"
SHA256_INTEL="$(awk '{print $1}' "$RELEASE_DIR/darwin-x86_64.dmg.sha256")"
PUB_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

jq -n \
  --arg version "$VERSION" \
  --arg notes "$NOTES" \
  --arg pub_date "$PUB_DATE" \
  --arg arm_signature "$ARM_SIG" \
  --arg arm_url "$DOWNLOAD_BASE/Tokcat_${VERSION}_aarch64.app.tar.gz" \
  --arg intel_signature "$INTEL_SIG" \
  --arg intel_url "$DOWNLOAD_BASE/Tokcat_${VERSION}_x64.app.tar.gz" \
  '{
    version: $version,
    notes: $notes,
    pub_date: $pub_date,
    platforms: {
      "darwin-aarch64": {signature: $arm_signature, url: $arm_url},
      "darwin-x86_64": {signature: $intel_signature, url: $intel_url}
    }
  }' > "$LATEST_JSON"

echo "==> latest.json"
cat "$LATEST_JSON"
echo "==> DMG sha256"
echo "darwin-aarch64 $SHA256_ARM"
echo "darwin-x86_64 $SHA256_INTEL"

# Tag must already exist (or be created here). We assume the commit is pushed.
if ! git rev-parse "$TAG" >/dev/null 2>&1; then
  echo "==> Tagging $TAG"
  git tag "$TAG"
  git push origin "$TAG"
fi

echo "==> Creating GitHub release"
gh release create "$TAG" \
  "$RELEASE_DIR/Tokcat_${VERSION}_aarch64.dmg" \
  "$RELEASE_DIR/Tokcat_${VERSION}_x64.dmg" \
  "$RELEASE_DIR/Tokcat_${VERSION}_aarch64.app.tar.gz" \
  "$RELEASE_DIR/Tokcat_${VERSION}_aarch64.app.tar.gz.sig" \
  "$RELEASE_DIR/Tokcat_${VERSION}_x64.app.tar.gz" \
  "$RELEASE_DIR/Tokcat_${VERSION}_x64.app.tar.gz.sig" \
  "$LATEST_JSON" \
  --title "Tokcat $VERSION" \
  --notes "$NOTES"

echo "==> Done: https://github.com/handlecusion/tokcat/releases/tag/$TAG"
echo "==> Manual tap update still required:"
echo "    arm sha256:   $SHA256_ARM"
echo "    intel sha256: $SHA256_INTEL"

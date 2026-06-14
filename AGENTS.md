# AGENTS.md

Project-specific instructions for Codex working on Tokcat.

## What this is

Tokcat is a native macOS menubar dashboard for the [`tokscale`](https://github.com/junhoyeo/tokscale) CLI.
Tauri 2 (Rust shell) + React/Vite frontend. Distribution is via GitHub Releases (DMG + auto-updater) and a Homebrew tap.

## Repos involved in a release

There are **two** repositories. A release touches both — never forget the tap.

1. **`~/Code/tokcat`** (this repo, `handlecusion/tokcat`) — app source, GitHub Releases, in-app updater manifest.
2. **`~/Code/homebrew-tokcat`** (`handlecusion/homebrew-tokcat`) — Homebrew tap with `Casks/tokcat.rb`. Brew users install from here.

## Release procedure

Releases are driven by **GitHub Actions** — push a `v<version>` tag and the workflow at `.github/workflows/release.yml` builds the DMG, publishes the GitHub Release, and bumps the Homebrew tap automatically. `scripts/release.sh` is kept as a manual fallback for the same flow on a local Mac.

### Required GitHub Secrets (one-time setup)

The Release workflow needs these in `https://github.com/handlecusion/tokcat/settings/secrets/actions`:

- `TAURI_SIGNING_PRIVATE_KEY` — full contents of `~/.tauri/tokcat.key` (the updater signing key)
- `TAURI_SIGNING_PRIVATE_KEY_PASSWORD` — optional, only if the key is password-protected
- `HOMEBREW_TAP_TOKEN` — a PAT with write access to `handlecusion/homebrew-tokcat` (classic: `repo` scope, or fine-grained: `Contents: read/write` on that single repo). Used by the `homebrew` job to commit the cask bump.

### 1. Bump the version in three files

The Release workflow asserts that the tag matches `package.json`, `src-tauri/Cargo.toml`, and `src-tauri/tauri.conf.json`. Bump all three by hand:

- `package.json` — `"version"` field
- `src-tauri/tauri.conf.json` — `"version"` field
- `src-tauri/Cargo.toml` — `version = "..."`

Then run `cargo check` from `src-tauri/` to refresh `Cargo.lock`.

### 2. Commit

Group changes into focused commits. The version bump itself goes into its own commit named exactly `Release Tokcat <version>` (matches existing history).

### 3. Push to `origin/main`

`git push origin main`.

### 4. Tag and push the tag

```sh
git tag -a v<VERSION> -m "<release notes>"     # annotated — message is reused in GH Release + latest.json
git push origin v<VERSION>
```

Unannotated tags work too; the workflow falls back to `"Tokcat <VERSION>"` as the GitHub Release body and in-app updater note.

Pushing the tag fires `.github/workflows/release.yml`, which:
- Verifies tag/package versions match
- Builds Apple Silicon on `macos-15` and Intel on `macos-15-intel`
- **Strips `.VolumeIcon.icns` from both DMGs** — Tauri's bundler embeds a 1.5 MB hidden volume icon that shows up next to `Tokcat.app` for any user with hidden files visible in Finder
- Generates `latest.json` with `darwin-aarch64` and `darwin-x86_64` entries (consumed by the in-app updater at `https://github.com/handlecusion/tokcat/releases/latest/download/latest.json`)
- Creates the GitHub Release with both DMGs, both arch-specific `.tar.gz` updater artifacts, signatures, and `latest.json`
- **Bumps `Casks/tokcat.rb` in `handlecusion/homebrew-tokcat`** (version + arm/intel sha256) and pushes to `main`

### 5. Verify

Watch the run: `gh run watch` or open Actions tab. After it succeeds:

```sh
# Confirm the published DMG has no .VolumeIcon.icns
gh release download v<VERSION> -p '*.dmg'
hdiutil attach -nobrowse "Tokcat_<VERSION>_aarch64.dmg"
ls -la /Volumes/Tokcat   # should show only .DS_Store, Applications, Tokcat.app
hdiutil detach /Volumes/Tokcat
hdiutil attach -nobrowse "Tokcat_<VERSION>_x64.dmg"
ls -la /Volumes/Tokcat   # should show only .DS_Store, Applications, Tokcat.app

# Confirm brew sees the new version
brew update && brew info --cask handlecusion/tokcat/tokcat
```

### Manual fallback: `scripts/release.sh`

If Actions is down or you need to publish from a local Mac, the legacy script still works. It does steps 4 + the GH Release publish but **does not** update the Homebrew tap — you must follow the old manual tap-bump procedure below.

```sh
scripts/release.sh <version> "<release notes>"

# Then manually bump the tap:
ARM_DMG_URL="https://github.com/handlecusion/tokcat/releases/download/v<VERSION>/Tokcat_<VERSION>_aarch64.dmg"
INTEL_DMG_URL="https://github.com/handlecusion/tokcat/releases/download/v<VERSION>/Tokcat_<VERSION>_x64.dmg"
curl -sL "$ARM_DMG_URL" | shasum -a 256
curl -sL "$INTEL_DMG_URL" | shasum -a 256
# Edit ~/Code/homebrew-tokcat/Casks/tokcat.rb — bump version + arm/intel sha256
cd ~/Code/homebrew-tokcat && git add Casks/tokcat.rb && git commit -m "Bump tokcat cask to <VERSION>" && git push origin main
```

Prerequisites for the manual script:
- `gh` CLI authenticated for `handlecusion/tokcat`
- Updater private key at `~/.tauri/tokcat.key` (or `TAURI_SIGNING_PRIVATE_KEY_PATH`)

## Repo conventions

- **Lockfiles**: `package-lock.json` is committed; `pnpm-lock.yaml` is ignored and should not be committed.
- **Commit style**: short imperative subject (~70 chars), optional body explaining the *why*. See recent history.
- **Dev server port**: `4061`. If you see `EADDRINUSE` on launch, a previous `pnpm dev`/`tauri:dev` left `node server.js` running. Clean up with:
  ```sh
  lsof -nP -iTCP:4061 -sTCP:LISTEN -t | xargs -r kill
  ```
- **`tokscale` dependency**: Tokcat shells out to the `tokscale` binary (search order: `/opt/homebrew/bin`, `/usr/local/bin`, `~/.cargo/bin`, then `PATH`). Do not reimplement its logic — see README for rationale.

## Things that have bitten us before

- **Forgetting the tap**: A successful `release.sh` run does **not** update Homebrew users. The tap repo is separate. Always do step 5.
- **Tag conflicts**: `release.sh` exits if `v<version>` already exists; if you need to redo a release, delete the tag locally + remotely first (`git tag -d v0.1.x && git push origin :refs/tags/v0.1.x`) — and consider whether bumping to the next patch is safer than overwriting.
- **DMG hidden files**: Tauri's DMG bundler always writes `.VolumeIcon.icns`. The cleanup step in `release.sh` handles it; do not remove that block.
- **`Casks/tokscale.rb` in the app repo**: This file used to live at `~/Code/tokcat/Casks/tokscale.rb` as a stale leftover from the `tokscale-3d` rename. It has been deleted. The actual cask lives in the tap repo; do not recreate it here.

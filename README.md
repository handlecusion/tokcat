<h1 align="center">Tokcat</h1>

<p align="center">
  <strong>AI token usage monitor for the macOS menu bar.</strong>
</p>

<p align="center">
  <a href="README.md">English</a> |
  <a href="README.ko-KR.md">한국어</a>
</p>

<p align="center">
  <a href="https://github.com/handlecusion/tokcat/releases/latest"><img src="https://img.shields.io/github/v/release/handlecusion/tokcat?style=flat-square&color=blue" alt="Release"></a>
  <a href="https://github.com/handlecusion/tokcat/stargazers"><img src="https://img.shields.io/github/stars/handlecusion/tokcat?style=flat-square" alt="Stars"></a>
  <a href="https://opensource.org/licenses/MIT"><img src="https://img.shields.io/badge/License-MIT-yellow.svg?style=flat-square" alt="MIT Licence"></a>
  <img src="https://img.shields.io/badge/macOS-11%2B-black?style=flat-square&logo=apple" alt="macOS 11+">
  <img src="https://img.shields.io/badge/Apple%20Silicon%20%2B%20Intel-arm64%20%2F%20x64-success?style=flat-square" alt="Apple Silicon and Intel">
  <img src="https://img.shields.io/badge/built%20with-Tauri%202-FFC131?style=flat-square&logo=tauri&logoColor=black" alt="Tauri 2">
</p>

<br>

You spent **$2,513.67** on AI coding tools in the last four months. You don't know that, because you can't see it.

**Tokcat** is an **AI token usage monitor for the macOS menu bar** — a local-first **Claude Code usage**, **Codex usage**, **Cursor usage**, and **LLM cost tracker** for AI coding agent usage. Built with **Tauri 2** (Rust shell + React/Vite frontend), Tokcat sits in the macOS menu bar — no Dock icon, no telemetry, no Tokcat account — and surfaces **9 AI coding clients** (Claude Code, Codex CLI, Cursor IDE, OpenCode, Gemini CLI, Copilot CLI, Amp, Droid, Hermes) in an Overview dashboard plus per-client tabs. The menu-bar title can show today's tokens, today's cost, totals, live tokens/min, or icon-only mode; clicking opens a frosted-glass popover with 2D stacked token bars, an interactive 3D contribution graph, OAuth agent-limit cards, Live session throughput, streak summaries, theme selection, and settings. Tokcat refreshes local usage data in-process, checks for signed updates every **30 minutes**, and ships as DMGs for **Apple Silicon and Intel Macs, macOS 11+**. Install: `brew install --cask handlecusion/tokcat/tokcat`.

<p align="center">
  <img src="docs/screenshots/menubar-cat2.gif" alt="Cat spinning next to today's cost in the menu bar" width="240" />
</p>

<p align="center">
  <img src="docs/screenshots/dashboard-3d.png" alt="Tokcat 3D contribution graph" width="640" />
</p>

---

## Quick Start

```sh
brew install --cask handlecusion/tokcat/tokcat
```

That's it. The fully-qualified `user/tap/cask` form auto-taps `handlecusion/homebrew-tokcat`. Open **Tokcat** from `/Applications` — the cat shows up in the menu bar, the Dock stays clean, and clicking the icon opens the dashboard.

The in-app updater checks for new releases on launch and again every 30 minutes; signed `.tar.gz` artifacts are verified against the embedded public key before install.

> Prefer a one-off DMG? Grab `Tokcat_<version>_aarch64.dmg` for Apple Silicon
> or `Tokcat_<version>_x64.dmg` for Intel from
> [Releases](https://github.com/handlecusion/tokcat/releases). No separate
> token-usage CLI is required.

---

## Find Tokcat by use case

Tokcat is built for the category searches people actually type when AI coding bills get fuzzy:

- **AI token usage monitor** for the **macOS menu bar**
- **Claude Code usage** tracker for local session logs
- **OpenAI Codex usage** and **Codex cost** tracker
- **Cursor usage** and **Cursor AI token** dashboard
- **LLM cost tracker** for AI coding agent usage across Claude Code, Codex CLI, Cursor IDE, Copilot CLI, Gemini CLI, OpenCode, Amp, Droid, and Hermes
- **AI coding dashboard** with Overview/client tabs, agent limits, live token velocity, streaks, and daily totals
- **GitHub-style 3D contribution graph** plus a recent 30-day stacked token chart

---

## Why Tokcat

| | |
|---|---|
| **Glanceable** | The menu bar title is configurable: today's tokens, today's cost, total tokens, total cost, live tokens/min, or icon-only. |
| **Native** | Tauri 2 shell with macOS `NSVisualEffectView` vibrancy, system fonts, and `prefers-color-scheme` light/dark adaptation. |
| **Quiet** | Lives in the menu bar — no Dock icon, no spurious notifications, auto-hides when you click another app. |
| **Honest** | Usage history comes from local session logs read on-device. No telemetry, no analytics, no cloud sync, no Tokcat account. |
| **Multi-client** | Tokcat reads Claude Code, Codex CLI, Cursor IDE, OpenCode, Gemini CLI, Copilot CLI, Amp, Droid, and Hermes logs. |
| **Cat** | The menubar cat eats your tokens and spins faster the more it digests — your token throughput as a single, glanceable critter. |

---

## How It Works

Tokcat reads local usage logs directly from the Rust backend. On demand from the tray menu, and on a steady background refresh for the popover chart, it scans supported client stores, deduplicates streaming retries, normalizes token fields, estimates cost from a bundled model-price table when the source log does not include cost, and caches the graph payload in memory.

For live activity, a JSONL tailer tracks recent growth in supported session logs and turns it into a 10-minute tokens/min signal. The same signal can drive the menu-bar title, the Live session card, and the adaptive tray animation.

For agent-limit cards, Tokcat reads existing Codex and Claude OAuth credentials and asks those vendors' usage endpoints for quota windows. Those direct vendor calls are separate from the local usage history and are not telemetry.

The React frontend renders the payload as an Overview dashboard with per-client tabs. Each tab shares the same year selector, theme picker, 2D/3D usage card, limit card, live session rows, and streak summaries.

### 2D stacked token chart

Recent 30-day token usage, stacked by client or narrowed to the active client tab. Hover for date, token, and cost detail.

<p align="center">
  <img src="docs/screenshots/dashboard-2d.png" alt="Tokcat 2D usage chart" width="640" />
</p>

### 3D contribution graph

Orthographic isometric projection with orbit controls and persistent camera state. The default framing auto-fits to the active tile cluster so populated days stay readable instead of getting lost in the empty future.

<p align="center">
  <img src="docs/screenshots/dashboard-3d.png" alt="Tokcat 3D tile graph" width="640" />
</p>

### Menubar settings

A native System Settings-styled panel for the menu-bar title, animated tray icon, launch-at-login, Live session detail, and one-click update check. The dashboard header also includes a theme picker, refresh button, and year selector.

<p align="center">
  <img src="docs/screenshots/settings.png" alt="Tokcat Settings panel" width="640" />
</p>

### A cat that eats tokens and spins

The mascot isn't decoration — it's the gauge. Tokcat's menubar cat eats whatever tokens your AI tools chew through and spins faster as it digests more. The hungrier your editor, the louder the cat. When you're idle, it dozes. When Claude Code is hammering through a refactor, it whirls. A glance at the menu bar and you know how fast your tokens are burning, without opening anything.

Pick between two styles in Settings: the spinning cat or a party parrot. During a manual refresh, the tray icon hops while Tokcat rebuilds the graph.

<p align="center">
  <img src="docs/screenshots/tray-anim-cat2.gif" alt="Spinning cat tray animation" width="128" />
</p>

---

## Features

| Feature | Details |
|---------|---------|
| **2D / 3D usage views** | Recent 30-day stacked token bars or interactive full-year 3D tile graph with orbit controls, persistent camera, and auto-fit-to-active-tiles framing. |
| **Overview + client tabs** | Switch between all-client totals and dedicated tabs for Claude Code, Codex CLI, Cursor IDE, OpenCode, Gemini CLI, Copilot CLI, Amp, Droid, and Hermes when data is present. |
| **Agent limits** | Codex and Claude OAuth quota cards show session, weekly, model, reset, and remaining-limit windows when local credentials are available. |
| **Live menu-bar title** | Today's tokens, today's cost, total tokens, total cost, live tokens/min, or icon-only. Token-rate updates are emitted every 3 minutes. |
| **Animated tray icon** | Optional spinning cat or party parrot animation whose FPS scales with your real-time token velocity. Native CALayer frame swaps keep the animation smooth in the macOS menu bar. |
| **Native vibrancy + glassmorphism** | Transparent window with macOS `sidebar` `NSVisualEffectView`; light/dark auto via `prefers-color-scheme`. |
| **Menubar popover behavior** | Chromeless window, drag region on the header, auto-hides when focus leaves the app. |
| **Theme picker** | Blue, Purple, Pink, Orange, Green, and Graphite palettes persist locally and adapt to light/dark mode. |
| **Settings panel** | macOS System Settings-styled preferences with switch toggles, sectioned groups, version info, and one-click update check. |
| **In-app updater** | Signed releases via Tauri updater. Silent check on launch and every 30 minutes; manual check from Settings or the tray menu. |
| **Launch at login** | Tauri autostart plugin — opt-in via Settings. |
| **Live session** | 10-minute tokens/min breakdown by client, with an optional split by agent and model. |
| **Streaks & summaries** | Longest / current streak, total tokens, total cost, daily average, best day. |
| **No telemetry** | Usage history stays local. Network calls are limited to signed update checks and direct Codex/Claude quota lookups when credentialed. |

---

## Usage

After installation, launch **Tokcat** from `/Applications`. Click the cat in the menu bar to open the dashboard. Right-click for the tray menu (Open, Settings…, Refresh Now, About, Check for Updates, Quit).

<details>
<summary><strong>Keyboard & menu shortcuts</strong></summary>
<br>

| Action | Shortcut |
|---|---|
| Open Settings | <kbd>⌘</kbd>,  (from tray menu) |
| Refresh now (bypass cache) | <kbd>⌘</kbd>R (from tray menu) |
| Quit Tokcat | <kbd>⌘</kbd>Q (from tray menu) |

</details>

<details>
<summary><strong>Settings</strong></summary>
<br>

| Setting | Effect |
|---|---|
| Menubar title | What the menu-bar text shows next to the icon, including the live tokens/min option. |
| Launch at login | Starts Tokcat automatically when you log in (Tauri autostart). |
| Animate tray icon | Spinning cat or party parrot animation that reflects token velocity. |
| Live trace → Split by agent / model | Expands the Live trace card from one row per client into per-agent and per-model rows. |
| About → Version | Currently installed Tokcat version. |
| About → Check Now | Same as the tray menu's "Check for Updates…", but in-pane. |
| Quit Tokcat | Exits the app. |

</details>

<details>
<summary><strong>Troubleshooting</strong></summary>
<br>

**Dashboard is empty or a client is missing**

Tokcat only reads local usage logs that already exist on disk. Open the AI client, complete at least one request, then choose Refresh Now from the tray menu. If you upgraded from an older Tokcat release that showed a missing-CLI setup dialog, update via Settings → About → Check Now, or `brew upgrade --cask tokcat`.

**Agent limits show Error or No quota**

Limit cards use local OAuth credentials from Codex and Claude. Run `codex login` or `claude` to refresh those credentials, then choose Refresh Now. API-key-only Codex auth can still produce local token history, but OAuth usage limits require OAuth login.

**The menu-bar window vanishes when I click anywhere**

That's intentional — Tokcat behaves like a native menubar popover. To keep it visible while interacting with another app, drag the window away from the menu bar by its header (anywhere outside the controls is a drag region).

**`brew install --cask tokcat` says no formula found**

Use the fully-qualified name so brew knows which tap to look in: `brew install --cask handlecusion/tokcat/tokcat`. If the tap itself is stale, refresh it with `brew update`.

**`Error: Cask tokcat exists in multiple taps`**

Earlier versions of the tap lived at `handlecusion/tokscale`; that repo was renamed to `handlecusion/homebrew-tokcat`. If you tapped the old name once, your local Homebrew still treats it as a separate tap and collides with the new one. Drop the stale tap and reinstall:

```sh
brew untap handlecusion/tokscale
brew install --cask handlecusion/tokcat/tokcat
```

**Downloaded DMG won't launch / "Tokcat is damaged" / immediate crash**

Tokcat ships ad-hoc-signed (no paid Apple Developer ID), so a DMG-installed copy hits the Gatekeeper quarantine. The Homebrew cask runs the strip + re-sign step automatically; for the manual DMG path do it yourself:

```sh
xattr -dr com.apple.quarantine /Applications/Tokcat.app
codesign --force --deep --sign - /Applications/Tokcat.app
open -na /Applications/Tokcat.app
```

</details>

---

## FAQ

### What is Tokcat?

Tokcat is a free, open-source native macOS menu-bar app that visualizes your AI coding token usage as a 2D stacked chart and 3D GitHub-style contribution graph. Its Tauri 2 backend reads local sessions from Claude Code, Codex CLI, Cursor IDE, OpenCode, Gemini CLI, Copilot CLI, Amp, Droid, and Hermes in one glanceable place. Tokcat makes zero analytics requests, requires no Tokcat account, and reads token history from local session logs. The app is MIT-licensed, distributed via Homebrew (`brew install --cask handlecusion/tokcat/tokcat`) and as DMGs from GitHub Releases, and targets Apple Silicon and Intel Macs running macOS 11 or newer.

### How much does Tokcat cost?

Tokcat is free and open-source under the MIT licence. There is no subscription, no paid tier, and no telemetry. Install with `brew install --cask handlecusion/tokcat/tokcat`.

### Which AI coding tools does Tokcat track?

Tokcat tracks **Claude Code, OpenAI Codex CLI, Cursor IDE, OpenCode, Google Gemini CLI, GitHub Copilot CLI, Amp, Droid, and Hermes** from local logs. New client formats are added in Tokcat's Rust usage reader.

### Does Tokcat send my data anywhere?

Tokcat does not send usage history to Tokcat servers and has no telemetry, analytics, cloud sync, or Tokcat account. It does make network requests for two explicit product functions: update checks against `https://github.com/handlecusion/tokcat/releases/latest/download/latest.json`, and direct Codex/Claude OAuth quota lookups against those vendors when local credentials are available. Token-usage history is read locally from session logs.

### How is Tokcat different from CLI token-usage tools?

Tokcat is a native macOS GUI and background reader: an animated menu-bar icon that shows cost, token count, or live tokens/min, a click-to-open frosted-glass dashboard with Overview/client tabs, 2D stacked token bars, an interactive 3D tile graph, agent-limit cards, Live session rows, streaks, themes, and a System Settings-styled preferences panel. It does not require a separate token-usage CLI at runtime.

### Does Tokcat run on Intel Macs or Windows?

Tokcat ships for **Apple Silicon (arm64) and Intel (x86_64) Macs on macOS 11 or later**. Windows support lives in the separate `handlecusion/tokcat-window` port repo; Linux is not supported.

### How do I uninstall Tokcat?

If installed via Homebrew: `brew uninstall --cask tokcat`. If installed via DMG: drag `Tokcat.app` from `/Applications` to the Trash. Tokcat writes preferences to `~/Library/Preferences/com.handlecusion.tokcat.plist` and a small settings file under `~/Library/Application Support/com.handlecusion.tokcat`; delete those manually if you want a clean removal.

---

## Build From Source

```sh
git clone https://github.com/handlecusion/tokcat.git
cd tokcat
pnpm install            # or: npm install
pnpm tauri:dev          # opens the menubar app with Vite HMR on :4061
pnpm tauri:build        # production .app + .dmg in src-tauri/target/release/bundle
```

The `dev` script runs the web frontend in a browser at `http://localhost:4061` against a small Express + Vite server (`server.js`) with a mock graph payload. Use `pnpm tauri:dev` when you need the native backend to read real local usage logs.

<details>
<summary><strong>Releasing a new version</strong></summary>
<br>

Releases are driven by GitHub Actions. Bump the version in `package.json`, `src-tauri/Cargo.toml`, and `src-tauri/tauri.conf.json`, run `cargo check` from `src-tauri/`, commit as `Release Tokcat <version>`, push `main`, then push an annotated `v<version>` tag.

```sh
git tag -a v<VERSION> -m "<release notes>"
git push origin main
git push origin v<VERSION>
```

The release workflow builds Apple Silicon and Intel DMGs, strips the embedded `.VolumeIcon.icns` (which would otherwise show up in Finder when hidden files are visible), generates signed updater artifacts and multi-platform `latest.json`, publishes the GitHub Release, and bumps `Casks/tokcat.rb` in [`handlecusion/homebrew-tokcat`](https://github.com/handlecusion/homebrew-tokcat).

`scripts/release.sh` remains a local fallback for publishing the app release, but it does not update the Homebrew tap.

</details>

---

## Repos involved

| Repo | Role |
|---|---|
| [`handlecusion/tokcat`](https://github.com/handlecusion/tokcat) | App source, GitHub Releases, in-app updater manifest |
| [`handlecusion/homebrew-tokcat`](https://github.com/handlecusion/homebrew-tokcat) | Homebrew tap (`Casks/tokcat.rb`) — what `brew install --cask handlecusion/tokcat/tokcat` resolves |
| [`junhoyeo/tokscale`](https://github.com/junhoyeo/tokscale) | Upstream CLI used as a reference for supported local log formats |

---

## Acknowledgements

Tokcat's local usage reader was informed by the open-source [`tokscale`](https://github.com/junhoyeo/tokscale) project. Special thanks to [@junhoyeo](https://github.com/junhoyeo) for documenting and maintaining that ecosystem knowledge.

---

## Licence

MIT. See [LICENSE](LICENSE).

<p align="center">
<br>
<code>brew install --cask handlecusion/tokcat/tokcat</code><br>
<sub>macOS 11+ · Apple Silicon + Intel · Tauri 2 · React / Vite · MIT</sub>
</p>

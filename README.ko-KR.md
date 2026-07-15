<h1 align="center">Tokcat</h1>

<p align="center">
  <strong>당신의 AI 토큰 사용량, macOS 메뉴바에서 살아 움직이게.</strong>
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

지난 4개월 동안 AI 코딩 도구에 **$2,513.67** 을 썼습니다. 그런데 모르고 있죠 — 볼 수 있는 곳이 없으니까.

**Tokcat**은 AI 코딩 토큰 사용량을 메뉴바에서 바로 볼 수 있게 해주는 네이티브 macOS 앱입니다. **Tauri 2**(Rust 셸 + React/Vite 프론트엔드)로 만들어졌으며, Dock 아이콘 없이 메뉴바에 상주하면서 텔레메트리·Tokcat 계정·클라우드 동기화 없이 동작합니다. **10종 AI 코딩 클라이언트**(Claude Code, Codex CLI, Cursor IDE, OpenCode, Gemini CLI, Copilot CLI, Amp, Droid, Hermes, Grok Build)를 Overview 대시보드와 클라이언트별 탭으로 보여주고, 메뉴바 고양이는 오늘의 토큰, 오늘의 비용, 전체 토큰/비용, live tokens/min 또는 아이콘만 표시할 수 있습니다. 클릭 시 macOS 비브런시(frosted glass) popover가 열려 2D 누적 토큰 차트, 3D 컨트리뷰션 그래프, OAuth agent limit, Live session, 스트릭 요약, 테마 선택, 설정 패널을 제공합니다. Tokcat은 로컬 사용량 로그를 앱 내부에서 읽어 갱신하고, **30분**마다 서명된 업데이트를 확인합니다. 배포는 **Apple Silicon 및 Intel Mac, macOS 11+** 용 DMG로 이루어집니다. 설치: `brew install --cask handlecusion/tokcat/tokcat`.

<p align="center">
  <img src="docs/screenshots/menubar-cat2.gif" alt="메뉴바에서 오늘의 비용 옆에 회전하는 고양이" width="240" />
</p>

<p align="center">
  <img src="docs/screenshots/dashboard-3d.png" alt="Tokcat 3D 컨트리뷰션 그래프" width="640" />
</p>

---

## 빠른 시작

```sh
brew install --cask handlecusion/tokcat/tokcat
```

이게 전부입니다. `/Applications`에서 **Tokcat**을 실행하면 메뉴바에 고양이가 나타나고 (Dock에는 표시되지 않음) 아이콘 클릭으로 대시보드가 열립니다. 별도의 토큰 사용량 CLI는 필요하지 않습니다.

인앱 업데이터는 실행 시 1회 + 30분마다 새 릴리스를 자동 확인합니다. 서명된 `.tar.gz` 아티팩트는 내장된 공개키로 검증된 후 설치됩니다.

> 일회성 DMG로 받고 싶다면
> [Releases](https://github.com/handlecusion/tokcat/releases) 페이지에서
> Apple Silicon은 `Tokcat_<version>_aarch64.dmg`, Intel Mac은
> `Tokcat_<version>_x64.dmg`를 받으세요. 이 경우에도 별도의 토큰 사용량 CLI
> 설치는 필요하지 않습니다.

---

## 왜 Tokcat인가

| | |
|---|---|
| **한눈에** | 메뉴바 타이틀에 표시할 항목을 선택할 수 있음 — 오늘의 토큰 / 오늘의 비용 / 전체 토큰 / 전체 비용 / 아이콘만. |
| **네이티브** | Tauri 2 셸 + macOS `NSVisualEffectView` 비브런시 + 시스템 폰트 + `prefers-color-scheme` 라이트/다크 자동 대응. |
| **조용함** | 메뉴바에만 상주 — Dock 아이콘 없음, 잡 알림 없음, 다른 앱 클릭 시 자동 hide. |
| **정직함** | 사용량 히스토리는 로컬 세션 로그를 기기 안에서 읽어 산출. 텔레메트리·분석·클라우드 동기화·Tokcat 계정 없음. |
| **다중 클라이언트** | Claude Code, Codex CLI, Cursor IDE, OpenCode, Gemini CLI, Copilot CLI, Amp, Droid, Hermes, Grok Build 로그 지원. |
| **고양이** | 메뉴바 고양이가 당신의 토큰을 받아먹고 더 많이 소화할수록 빠르게 회전합니다 — 한 마리 생물로 표현된 토큰 처리량. |

---

## 동작 방식

Tokcat은 Rust 백엔드에서 로컬 사용량 로그를 직접 읽습니다. 트레이 메뉴의 즉시 새로고침과 popover 차트용 백그라운드 갱신 시 지원 클라이언트 저장소를 스캔하고, 스트리밍 재시도 이벤트를 중복 제거하고, 토큰 필드를 정규화하며, 원본 로그에 비용 정보가 없으면 내장 모델 가격표로 비용을 추정한 뒤 그래프 페이로드를 메모리에 캐시합니다.

React 프런트엔드는 이 페이로드를 받아 Overview 대시보드와 클라이언트별 탭으로 렌더링합니다. 각 탭은 같은 연도 선택, 테마 선택, 2D/3D 사용량 카드, Live session, 스트릭 요약을 공유합니다.

### 2D 누적 토큰 차트

최근 30일 토큰 사용량을 클라이언트별로 누적해 보여줍니다. 탭을 바꾸면 해당 클라이언트의 로컬 토큰 히스토리만 좁혀 볼 수 있습니다.

<p align="center">
  <img src="docs/screenshots/dashboard-2d.png" alt="Tokcat 2D 누적 토큰 차트" width="640" />
</p>

### 3D 컨트리뷰션 그래프

직교 아이소메트릭 투영 + orbit 컨트롤 + 카메라 영속화. 기본 framing은 active 타일 클러스터에 자동 fit되므로 사용 중인 날들이 빈 미래에 묻히지 않고 또렷하게 보입니다.

<p align="center">
  <img src="docs/screenshots/dashboard-3d.png" alt="Tokcat 3D 타일 그래프" width="640" />
</p>

### Settings 패널

macOS System Settings 스타일의 네이티브 패널 — 메뉴바 타이틀 / 트레이 애니메이션 / 로그인 시 자동 실행 / 원클릭 업데이트 확인.

<p align="center">
  <img src="docs/screenshots/settings.png" alt="Tokcat Settings 패널" width="640" />
</p>

### 토큰을 먹고 회전하는 고양이

마스코트가 아니라 게이지입니다. Tokcat의 메뉴바 고양이는 AI 도구들이 씹어 삼키는 토큰을 그대로 받아먹고, 더 많이 소화할수록 더 빠르게 돕니다. 편집기가 배고플수록 고양이는 시끄러워지고, 가만히 있으면 고양이도 졸음에 빠집니다. Claude Code가 리팩터링을 두들기는 동안엔 빙빙 돌고, 토큰이 흐르지 않으면 멈춥니다. 메뉴바를 한 번 흘낏 보는 것만으로 토큰이 얼마나 빠르게 타고 있는지 알 수 있습니다 — 어떤 창도 열지 않고요.

Settings에서 두 가지 스타일 선택 가능: 회전하는 고양이 또는 party parrot.

<p align="center">
  <img src="docs/screenshots/tray-anim-cat2.gif" alt="회전하는 고양이 트레이 애니메이션" width="128" />
</p>

---

## 기능

| 기능 | 설명 |
|------|------|
| **2D / 3D 사용량 보기** | 최근 30일 누적 토큰 차트 또는 full-year 3D 타일 그래프. orbit 컨트롤, 카메라 상태 저장, active 타일 자동 fit. |
| **Overview + 클라이언트 탭** | 데이터가 있는 Claude Code, Codex CLI, Cursor IDE, OpenCode, Gemini CLI, Copilot CLI, Amp, Droid, Hermes, Grok Build 탭으로 전환. |
| **Agent limits** | 로컬 OAuth credential이 있으면 Codex/Claude/Grok session, weekly, credits, model, reset, remaining limit window 표시. |
| **라이브 메뉴바 타이틀** | 오늘의 토큰 / 오늘의 비용 / 전체 토큰 / 전체 비용 / 아이콘만. 토큰 처리량 업데이트는 3분마다 전달됩니다. |
| **트레이 아이콘 애니메이션** | 회전하는 고양이 또는 party parrot 애니메이션 속도가 실시간 토큰 처리량에 따라 변동. |
| **네이티브 비브런시 + 글래스모피즘** | 투명 윈도우 + macOS `sidebar` 머티리얼; 라이트/다크 자동 전환. |
| **메뉴바 popover 동작** | chromeless 윈도우, 헤더 드래그 영역, 다른 앱 클릭 시 자동 hide. |
| **테마 선택** | Blue, Purple, Pink, Orange, Green, Graphite palette를 로컬에 저장하고 라이트/다크 모드에 맞춰 적용. |
| **Settings 패널** | macOS System Settings 스타일 — 스위치 토글, 카드 그룹, 버전 표시, 원클릭 업데이트 확인. |
| **인앱 자동 업데이트** | 서명된 Tauri 업데이터. 시작 시 + 30분마다 silent 체크. Settings/트레이 메뉴에서 수동 체크 가능. |
| **로그인 시 자동 실행** | Tauri autostart 플러그인 — Settings에서 활성화. |
| **스트릭 & 요약** | 최장/현재 스트릭, 누적 토큰, 누적 비용, 일평균, 최고 사용일. |
| **텔레메트리 없음** | 사용량 히스토리는 로컬에 머무릅니다. 네트워크 요청은 서명된 업데이트 확인과 credential이 있을 때의 Codex/Claude/Grok quota 조회로 제한됩니다. |

---

## 사용법

설치 후 `/Applications`에서 **Tokcat**을 실행하세요. 메뉴바의 고양이 아이콘 클릭으로 대시보드를 엽니다. 우클릭으로 트레이 메뉴(Open, Settings…, Refresh Now, About, Check for Updates, Quit) 가 표시됩니다.

<details>
<summary><strong>키보드 및 메뉴 단축키</strong></summary>
<br>

| 동작 | 단축키 |
|---|---|
| Settings 열기 | <kbd>⌘</kbd>, (트레이 메뉴) |
| 즉시 새로고침 (캐시 무시) | <kbd>⌘</kbd>R (트레이 메뉴) |
| Tokcat 종료 | <kbd>⌘</kbd>Q (트레이 메뉴) |

</details>

<details>
<summary><strong>Settings 항목</strong></summary>
<br>

| 항목 | 효과 |
|---|---|
| Menubar title | 메뉴바 아이콘 옆에 표시할 텍스트 종류 |
| Launch at login | 로그인 시 Tokcat 자동 시작 (Tauri autostart) |
| Animate tray icon | 고양이/큐브 애니메이션 (토큰 처리량에 비례한 속도) |
| About → Version | 현재 설치된 Tokcat 버전 |
| About → Check Now | 트레이 메뉴의 "Check for Updates…"와 동일하지만 패널 안에서 실행 |
| Quit Tokcat | 앱 종료 |

</details>

<details>
<summary><strong>문제 해결</strong></summary>
<br>

**대시보드가 비어 있거나 특정 클라이언트가 보이지 않음**

Tokcat은 디스크에 이미 존재하는 로컬 사용량 로그만 읽습니다. 해당 AI 클라이언트에서 최소 한 번 요청을 완료한 뒤 트레이 메뉴의 Refresh Now를 실행하세요. 예전 Tokcat 버전에서 CLI 설치 안내 다이얼로그가 보였다면 Settings → About → Check Now 또는 `brew upgrade --cask tokcat`으로 업데이트하세요.

**다른 곳을 클릭하면 메뉴바 윈도우가 사라짐**

이는 의도된 동작입니다 — 표준 macOS 메뉴바 popover처럼 동작합니다. 다른 앱과 함께 보면서 작업하려면 헤더의 빈 영역(컨트롤이 없는 부분)을 잡아 드래그해 메뉴바에서 떼어 놓으면 됩니다.

**`brew install --cask tokcat` 시 formula not found**

정확한 tap/cask 이름으로 설치하세요: `brew install --cask handlecusion/tokcat/tokcat`. tap이 오래됐다면 `brew update`를 먼저 실행하세요.

</details>

---

## 자주 묻는 질문 (FAQ)

### Tokcat이 뭔가요?

Tokcat은 AI 코딩 도구의 토큰 사용량을 2D 누적 차트와 3D GitHub 스타일 컨트리뷰션 그래프로 시각화해주는 무료 오픈소스 macOS 메뉴바 앱입니다. Tauri 2 백엔드가 Claude Code, Codex CLI, Cursor IDE, OpenCode, Gemini CLI, Copilot CLI, Amp, Droid, Hermes, Grok Build 세션을 로컬 로그에서 읽어 한 화면에 보여줍니다. 분석 요청을 보내지 않고, Tokcat 계정도 필요 없습니다. MIT 라이선스로 공개되어 있으며, Homebrew(`brew install --cask handlecusion/tokcat/tokcat`) 또는 GitHub Releases의 DMG로 배포됩니다. **Apple Silicon 및 Intel Mac, macOS 11 이상** 대상입니다.

### 비용이 얼마인가요?

Tokcat은 MIT 라이선스 무료 오픈소스입니다. 구독, 유료 등급, 텔레메트리가 없습니다. 설치는 `brew install --cask handlecusion/tokcat/tokcat`.

### 어떤 AI 코딩 도구를 추적하나요?

로컬 로그 기준으로 **Claude Code, OpenAI Codex CLI, Cursor IDE, OpenCode, Google Gemini CLI, GitHub Copilot CLI, Amp, Droid, Hermes, Grok Build**를 추적합니다. 새 클라이언트 포맷은 Tokcat의 Rust 사용량 리더에 추가됩니다.

### Tokcat은 제 데이터를 어디로 보내나요?

Tokcat 서버로 사용량 히스토리를 보내지 않고, 텔레메트리·분석·클라우드 동기화·Tokcat 계정이 없습니다. 네트워크 요청은 새 릴리스 확인을 위한 `https://github.com/handlecusion/tokcat/releases/latest/download/latest.json` 조회와, 로컬 credential이 있을 때 Codex/Claude/Grok quota를 직접 조회하는 요청으로 제한됩니다. 토큰 사용 히스토리는 디스크의 세션 로그에서 로컬로 읽습니다.

### CLI 토큰 사용량 도구와 어떻게 다른가요?

Tokcat은 네이티브 macOS GUI이자 백그라운드 로컬 로그 리더입니다 — 비용/토큰/live tokens/min을 보여주는 애니메이션 고양이 메뉴바 아이콘, 클릭으로 열리는 frosted-glass 대시보드(Overview/client tabs, 2D 누적 토큰 차트, 인터랙티브 3D 타일 그래프, agent-limit cards, Live session, 스트릭, 테마, System Settings 스타일 설정 패널)를 제공합니다. 런타임에 별도 토큰 사용량 CLI가 필요하지 않습니다.

### Intel Mac이나 Windows에서 돌아가나요?

Tokcat은 **Apple Silicon(arm64) 및 Intel(x86_64) Mac, macOS 11 이상**을 지원합니다. Windows 지원은 별도 `handlecusion/tokcat-window` 포트 repo에서 진행합니다. Linux는 지원하지 않습니다.

### 어떻게 제거하나요?

Homebrew로 설치한 경우: `brew uninstall --cask tokcat`. DMG로 설치한 경우: `/Applications`에서 `Tokcat.app`을 휴지통으로 옮기세요. Tokcat은 `~/Library/Preferences/com.handlecusion.tokcat.plist`와 `~/Library/Application Support/com.handlecusion.tokcat`에 설정을 저장하므로, 완전 제거를 원하면 두 경로를 수동 삭제하세요.

---

## 소스에서 빌드

```sh
git clone https://github.com/handlecusion/tokcat.git
cd tokcat
pnpm install            # 또는 npm install
pnpm tauri:dev          # 메뉴바 앱 + Vite HMR (:4061)
pnpm tauri:build        # 프로덕션 .app + .dmg → src-tauri/target/release/bundle
```

`pnpm dev`는 브라우저(`http://localhost:4061`)에서 웹 프런트엔드만 실행하며 작은 Express + Vite 서버(`server.js`)가 mock graph 페이로드를 제공합니다. 실제 로컬 사용량 로그를 읽어야 할 때는 `pnpm tauri:dev`를 사용하세요.

<details>
<summary><strong>새 버전 릴리스</strong></summary>
<br>

```sh
# 1. package.json, src-tauri/tauri.conf.json, src-tauri/Cargo.toml에 버전 bump
# 2. cargo check (Cargo.lock 갱신)
# 3. 커밋 후 origin/main에 푸시
scripts/release.sh <version> "<release notes>"
```

`scripts/release.sh`는 Apple Silicon 및 Intel용 프로덕션 앱과 DMG를 빌드하고, 내장 `.VolumeIcon.icns`를 제거(Finder에서 숨김 파일 표시 시 보이는 잔존 캐시) 한 후, 업데이터 서명을 생성하고, multi-platform `latest.json`을 작성하고, 태그를 만들어 `gh release create`로 일괄 업로드합니다.

릴리스 후 [`handlecusion/homebrew-tokcat`](https://github.com/handlecusion/homebrew-tokcat)의 `Casks/tokcat.rb`도 갱신해야 brew 사용자가 새 버전을 받을 수 있습니다.

</details>

---

## 관련 리포지토리

| Repo | 역할 |
|---|---|
| [`handlecusion/tokcat`](https://github.com/handlecusion/tokcat) | 앱 소스, GitHub Releases, 인앱 업데이터 매니페스트 |
| [`handlecusion/homebrew-tokcat`](https://github.com/handlecusion/homebrew-tokcat) | Homebrew tap (`Casks/tokcat.rb`) — `brew install --cask handlecusion/tokcat/tokcat`이 가리키는 곳 |
| [`junhoyeo/tokscale`](https://github.com/junhoyeo/tokscale) | 지원 로컬 로그 포맷을 참고한 상류 CLI |

---

## 감사의 말

Tokcat의 로컬 사용량 리더는 오픈소스 [`tokscale`](https://github.com/junhoyeo/tokscale) 프로젝트에서 많은 포맷 지식을 참고했습니다. 해당 프로젝트를 만들고 유지보수해 주시는 [@junhoyeo](https://github.com/junhoyeo)님께 감사드립니다.

---

## 라이선스

MIT. [LICENSE](LICENSE) 참고.

<p align="center">
<br>
<code>brew install --cask handlecusion/tokcat/tokcat</code><br>
<sub>macOS 11+ · Apple Silicon + Intel · Tauri 2 · React / Vite · MIT</sub>
</p>

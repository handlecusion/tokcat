# Claude harness — 이슈를 Claude Code 클라우드 세션에 위임하기

오너가 이슈에 `claude` 라벨을 붙이면 Claude Code **클라우드 세션**이 뜨고, 세션 링크가
이슈에 달리고, Claude가 구현 → PR → 셀프 리뷰까지 하고, 오너 승인 뒤 CI가 통과하면
`main`에 자동 머지된다. 러너에는 Claude 크리덴셜이 전혀 없다.

```
누구나 이슈 작성
  └─ 오너가 `claude` 라벨 ──▶ claude-dispatch.yml
                               ├─ 오너 검증 (sender == repository_owner, 2중)
                               ├─ 페이로드 조립: 제목·본문·댓글 + AGENTS.md, docs/llms-full.txt,
                               │                 이슈가 언급한 스펙/파일 (≤60k chars)
                               ├─ POST routine /fire  ──▶ Claude Code 클라우드 세션 (앱 Code 탭에 표시)
                               └─ 이슈 코멘트: 🛰️ 세션 링크 + <!-- claude-harness session=… -->
세션 (ROUTINE_PROMPT.md)
  ├─ 요구사항 부족 → 이슈에 질문 + `claude:needs-info`    ─┐
  └─ 충분 → claude/issue-N 브랜치 → PR (설명·검증법) + 셀프 리뷰 코멘트 + `claude:pr-open`
오너가 `@claude …` 로 답변/리뷰 ──▶ claude-followup.yml ──▶ 후속 세션 (같은 브랜치 이어서)
오너가 PR 승인(리뷰 Approve 또는 `approved` 라벨) ──▶ claude-merge-gate.yml
                               └─ gh pr merge --auto → 룰셋 필수 체크(CI 3종) 통과 시 머지
```

## 왜 "컨테이너 안에서 claude CLI"가 아니라 routine `/fire`인가

- `claude setup-token`의 `CLAUDE_CODE_OAUTH_TOKEN`은 **모델 호출만** 가능하고 클라우드
  세션·Remote Control을 만들 수 없다(공식 문서). 러너에서 `claude --cloud`는 성립하지 않는다.
- 사용자의 전체 OAuth 로그인 토큰을 시크릿으로 넣으면 만료·리프레시 회전 문제가 있고
  계정 전체 권한이 러너에 들어간다.
- Routine API 트리거는 CI 파이프라인용으로 만들어진 공식 경로다. 토큰은 **그 루틴 하나를
  발화하는 것만** 가능하고 읽기 권한이 없다. 응답으로 세션 ID/URL을 바로 준다.

## 구성 요소

| 파일 | 역할 |
| --- | --- |
| `.github/workflows/claude-dispatch.yml` | `issues.labeled(claude)` → 세션 발화 + 링크 코멘트. `workflow_dispatch`(DISPATCH/DRY_RUN)로 수동 실행 가능 |
| `.github/workflows/claude-followup.yml` | 오너의 `@claude` 코멘트/리뷰 → 후속 세션. 시간당 3회 상한 |
| `.github/workflows/claude-merge-gate.yml` | 오너 승인(리뷰 Approve / `approved` 라벨) → auto-merge. 라벨 제거·변경 요청·새 푸시 시 해제. 머지되면 연결 이슈를 닫고 라벨 정리 |
| `scripts/claude-harness/build-payload.py` | 이슈/PR + 토론 + 문서·스펙을 한 텍스트로 조립 |
| `scripts/claude-harness/fire.sh` | `/fire` 호출, 429/5xx 재시도, 세션 ID/URL 출력 |
| `.claude/harness/ROUTINE_PROMPT.md` | 이슈 위임 세션이 따르는 지침의 원본. 클론에 있으면 claude.ai에 저장된 사본보다 우선 |
| `.claude/harness/REVIEW_PROMPT.md` | PR 자동 리뷰 세션의 지침 원본 (같은 우선순위 규칙) |

라벨: `claude`(트리거, 오너 전용) · `claude:running` · `claude:needs-info` · `claude:pr-open` · `approved`(머지 게이트, 오너 전용)

## 1회 설정

1. **루틴 (이슈 위임)**: https://claude.ai/code/routines/trig_01QJ58u3U5nURAPzWJtXytGp — "tokcat · Claude harness (issue delegation)".
   저장소 `handlecusion/tokcat`, 모델 `claude-opus-5`, 환경 `askai`(Trusted 네트워크; GitHub는 프록시 경유).
   저장된 프롬프트는 `ROUTINE_PROMPT.md`의 스냅샷이고, 클론에 이 파일이 있으면 파일이 우선한다.
   파일을 고치면 루틴의 스냅샷도 같은 내용으로 갱신해 둘 것(웹 편집 또는 CLI `/schedule update`).
2. **API 트리거 토큰**: 루틴 편집 → *Add another trigger* → *API* → *Generate token*. URL과 토큰을
   저장소 시크릿에 넣는다 (토큰은 한 번만 보인다):
   ```sh
   gh secret set CLAUDE_ROUTINE_FIRE_URL   -R handlecusion/tokcat   # https://api.anthropic.com/v1/claude_code/routines/trig_…/fire
   gh secret set CLAUDE_ROUTINE_FIRE_TOKEN -R handlecusion/tokcat   # sk-ant-oat01-…
   ```
   토큰 재발급은 같은 화면의 *Regenerate* — 이전 토큰은 즉시 무효.
3. **저장소 설정**(이미 적용됨): *Allow auto-merge* 켜기, 룰셋 `protect-main`에 필수 상태 체크
   `Frontend typecheck` / `Rust check` / `Swift build + test` 추가. CI 잡 이름을 바꾸면 룰셋도 같이 바꿀 것.
4. 세션이 GitHub에 쓰려면 claude.ai 계정에 GitHub이 연결돼 있어야 한다 (Claude GitHub App — 2026-08-30 연결 완료,
   앱은 `handlecusion` 계정 전체 저장소에 설치됨). 클라우드 VM에는 `gh`가 **없고** 내장 GitHub MCP 도구
   (`add_issue_comment`, `issue_write`, `create_pull_request`, `pull_request_review_write`, …)로 쓴다.

5. **루틴 (PR 자동 리뷰)**: https://claude.ai/code/routines/trig_01BswRvckXcbV6xSM9CkLQxQ — "tokcat · PR auto-review".
   GitHub 트리거 `pull_request.opened` (Claude GitHub App 웹훅, Actions 불필요).
   **실측 제약(2026-08-31)**: 구독을 걸어도 `ready_for_review`·`reopened`는 세션을 만들지 않았고
   `opened`만 전달됐다(#75–#79에서 5/5). 즉 **웹훅 생성 이전에 열린 PR과 draft→ready 전환 PR은
   자동 리뷰가 붙지 않는다** — 필요하면 리뷰 세션 링크 없이 사람이 보거나, 새 PR로 다시 연다.
   또 웹훅 발화에는 시간당 상한이 있어(프리뷰) 몰리면 조용히 드롭된다.
   PR이 열리면 세션이 diff를 읽고 **COMMENT 리뷰**(인라인 + 총평, 마커 `kind=REVIEW`)를 남긴다.
   승인/변경요청은 절대 하지 않는다(머지 게이트와 분리). 프리뷰 기간엔 웹훅 발화에 시간당 상한이 있다.
   **트러스트 경계**: 같은 저장소 PR은 워크스페이스가 PR 헤드로 체크아웃된 채 시작되므로, 리뷰 세션은
   지침(AGENTS.md, REVIEW_PROMPT.md)을 반드시 `origin/main`에서 `git show`로 읽는다 — PR 트리의 하네스
   파일은 리뷰 대상일 뿐이다. 루틴에 저장된 부트스트랩도 같은 규칙을 강제한다.
   `@claude` 후속 세션은 **Claude가 연 PR(`claude/*`)에서만** 뜬다 — 일반 PR의 자동 리뷰에 이의가 있으면
   사람이 직접 처리하거나, 리뷰 세션 링크(앱 Code 탭)를 열어 그 세션에 이어서 물어보면 된다.

## 운용

- **드라이런**: `gh workflow run claude-dispatch.yml -f issue_number=<N> -f kind=DRY_RUN` (또는
  로컬에서 `GH_REPO=handlecusion/tokcat scripts/claude-harness/build-payload.py --kind DRY_RUN --issue N > p.txt && scripts/claude-harness/fire.sh p.txt`).
  세션이 이슈에 "harness dry run OK" 코멘트를 남기면 경로 전체가 살아 있는 것.
  (2026-08-30 E2E 검증: #70 DRY_RUN, #71→PR #72 — 라벨 → 세션 → PR+인라인 셀프 리뷰 → `@claude` 리뷰 반영 →
  `approved` → auto-merge. 머지는 github-actions[bot]이 수행하므로 `issues: write` 없이는 `Closes #N`이 안 닫힌다.)
- **재실행**: `claude:running`을 뗀 뒤, `claude` 라벨을 떼었다가 다시 붙인다(라벨 *추가* 이벤트가 트리거).
- **질문 답변**: `claude:needs-info`가 붙어 있는 동안은 오너의 아무 코멘트나 후속 세션을 띄운다. 그 외에는
  코멘트/리뷰(인라인 코멘트 포함) 어딘가에 `@claude`가 있어야 한다. Claude 글을 Quote-reply 해도 된다.
- **동시 실행 방지**: 스레드에 `claude:running`이 있으면 후속 세션을 띄우지 않는다. 세션이 죽어 라벨만 남았으면
  라벨을 떼거나 코멘트에 `[force]`를 넣는다. PR 후속 세션은 끝날 때 스스로 `claude:running`을 뗀다.
- **머지**: Claude의 PR은 오너 계정 명의로 열리기 때문에 GitHub이 셀프 Approve를 막는다 →
  `approved` 라벨이 승인이다. 남이 연 PR은 리뷰 Approve로도 된다. 포크에서 온 PR은 토큰이
  읽기 전용이라 게이트가 못 건드린다 — 직접 머지.
- **루틴 디버깅**: 세션 링크를 열거나, CLI에서 `/schedule why did … do nothing` 식으로 런 로그를 본다.
  세션이 안 뜨는데 코멘트도 없다면 워크플로우 런 로그(`🛰️ … 세션을 띄우지 못했습니다` 코멘트에 링크).
- **한도**: 루틴 런은 계정별 일일 상한이 있고 구독 사용량을 쓴다. `fire.sh`는 429/503/무응답만 재시도한다(`/fire`는
  멱등이 아니라 5xx 재시도는 세션을 두 개 만들 수 있음). 실패 코멘트에 세션 링크가 있으면 라벨을 다시 붙이지 말 것.
- **지켜볼 것**: (1) auto-merge로 머지된 커밋은 GITHUB_TOKEN 이벤트라 `push: main` CI가 돌지 않는다(PR CI가 이미 통과).
  (2) 룰셋의 `require_extra_approval_for_unattributed_changes`가 Claude 커밋(작성자 귀속 문제)에 걸려 auto-merge가
  멈추면 그 옵션을 끄거나 커밋 작성자를 오너로 맞춘다. 첫 실제 PR에서 확인할 것.

## 보안 경계

- 트리거는 **오너의 라벨/코멘트/승인**뿐이다. 표현식 `if:`와 잡 안의 셸 검증으로 두 번 확인한다.
- 이슈 본문·댓글은 페이로드에 인용문으로 들어가고, 세션은 그것을 "요구사항"으로 읽지 지시로 읽지 않는다
  (루틴 프롬프트가 그렇게 못 박고, 서비스도 `<routine-fire-payload>`로 감싸 신뢰하지 않는 데이터로 표시).
- Claude의 GitHub 글은 오너 계정으로 올라간다. 그래서 모든 글에 `🤖 **Claude Code**` 머리와
  `<!-- claude-harness … -->` 꼬리를 강제하고, 하네스는 그 마커가 있는 글을 무시한다. Claude는 `@claude`를 절대 쓰지 않는다.
- 루프 상한: 스레드당 시간당 세션 3회.
- 세션은 `main`에 푸시할 수 없고(클라우드 푸시 보호 + 룰셋), 머지·승인·auto-merge를 하지 않도록 지시돼 있다.
- **정체성 구분.** 세션의 GitHub 쓰기는 오너 계정이지만 **Claude GitHub App을 통해**
  이루어져 `performed_via_github_app.slug == "claude"`가 찍힌다(#68 드라이런으로 확인). 하네스는 이걸로
  사람과 세션을 가른다: 후속 트리거는 앱 경유 코멘트를 무시하고, 머지 게이트는 `approved` 라벨의
  이벤트가 앱 경유면 라벨을 떼고 거부한다. 프롬프트 인젝션으로 세션이 스스로 승인하는 경로는 이걸로 막힌다.
- **승인은 리뷰한 커밋에만.** 승인 뒤 새 푸시(`synchronize`)가 오면 `approved` 라벨과 auto-merge를 해제하고,
  룰셋도 `dismiss_stale_reviews_on_push`라 리뷰 Approve도 무효가 된다.
- **남는 구멍과 권장 보강.** 리뷰 Approve 경로는 앱 경유 여부를 API가 알려주지 않는다(리뷰 객체에 그 필드가 없음).
  세션은 자기 PR을 승인할 수 없고(오너 본인 PR) 승인하지 말라고 지시돼 있지만, 타인 PR을 승인하는 경로는
  프롬프트에만 기댄다. 완전히 닫으려면 클라우드 환경 변수에 **전용 머신 계정의 `GH_TOKEN`**을 넣어
  세션이 오너가 아닌 별도 계정으로 쓰게 하면 된다 — 그러면 모든 `sender == owner` 게이트가 정확해지고,
  오너가 Claude의 PR을 리뷰 Approve로 승인할 수도 있게 된다.

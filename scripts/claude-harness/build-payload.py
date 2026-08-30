#!/usr/bin/env python3
"""Build the routine-fire payload for the Claude harness.

The payload is the `text` field POSTed to the routine's `/fire` endpoint. The
cloud session receives it wrapped in a `<routine-fire-payload>` block, so it
must be self-describing: everything the session needs to start working on an
issue without asking twice.

Runs on the GitHub Actions runner and on a developer Mac. Needs `gh` (authed)
and `git`. Reads `GH_REPO` (owner/repo) from the environment, as `gh` does.

Usage:
  build-payload.py --kind DISPATCH  --issue 123
  build-payload.py --kind DRY_RUN   --issue 123
  build-payload.py --kind FOLLOW_UP --issue 123 --comment-id 987654
  build-payload.py --kind FOLLOW_UP --issue 130 --review-id 456     # 130 is a PR
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path

HARNESS_MARKER = "<!-- claude-harness"
SESSION_RE = re.compile(r"session=(session_[A-Za-z0-9]+|cse_[A-Za-z0-9]+)")
# Workflow plumbing (session links, skips, errors, merge-gate notes) is posted by the
# Actions token, i.e. by github-actions[bot]. Only the author is trusted — never the
# marker text, which anyone can paste.
PLUMBING_LOGIN = "github-actions[bot]"


def is_plumbing(c: dict) -> bool:
    return (c.get("user") or {}).get("login") == PLUMBING_LOGIN


def is_claude_post(c: dict) -> bool:
    """A post made by a Claude cloud session: the owner's identity via the Claude GitHub App."""
    app = c.get("performed_via_github_app") or {}
    return app.get("slug") == "claude"


def quote(text: str) -> str:
    """Neutralise section delimiters inside untrusted text so it cannot forge payload structure."""
    text = text.replace("CLAUDE HARNESS PAYLOAD", "CLAUDE HARNESS PAYLOAD (quoted)")
    return re.sub(r"^(--- |\[)", lambda m: "\u2063" + m.group(1), text, flags=re.M)
# Tokens that look like repository paths: contain a slash or a file extension.
PATH_RE = re.compile(r"(?<![\w/])((?:[\w.-]+/)+[\w.-]+|[\w-]+\.(?:md|swift|rs|ts|tsx|js|json|yml|yaml|sh|py|plist|txt|css|html))(?![\w/])")
# github.com/<owner>/<repo>/blob|tree/<ref>/<path> links → repo-relative path
GH_URL_RE = re.compile(r"https?://github\.com/[^/\s]+/[^/\s]+/(?:blob|tree)/[^/\s]+/([^\s#?)\]>]+)")

# Docs every dispatch carries. AGENTS.md is the contributor contract; llms-full
# is the product ground truth. README is listed, not inlined (too long).
ALWAYS_INLINE = ["AGENTS.md", "docs/llms-full.txt"]
ALWAYS_LIST = ["README.md", "README.ko-KR.md"]
CONDITIONAL_DOCS = [
    (re.compile(r"landing|docs/index\.html|website|랜딩|styles\.css|remotion", re.I), "design/landing-style-reference.md"),
    (re.compile(r"release|sparkle|appcast|homebrew|cask|릴리즈|배포", re.I), ".github/workflows/release-native.yml"),
]


def sh(*args: str, check: bool = True) -> str:
    proc = subprocess.run(args, capture_output=True, text=True)
    if check and proc.returncode != 0:
        sys.stderr.write(proc.stderr)
        raise SystemExit(f"command failed: {' '.join(args)}")
    return proc.stdout


def gh_json(path: str, paginate: bool = False):
    args = ["gh", "api", path]
    if paginate:
        args += ["--paginate", "--slurp"]
    out = sh(*args)
    data = json.loads(out) if out.strip() else []
    if paginate:
        # --slurp yields a list of pages; flatten.
        flat = []
        for page in data:
            flat.extend(page if isinstance(page, list) else [page])
        return flat
    return data


def repo_files(root: Path) -> set[str]:
    out = sh("git", "-C", str(root), "ls-files", check=False)
    return set(line.strip() for line in out.splitlines() if line.strip())


def clip(text: str, limit: int, label: str) -> str:
    if len(text) <= limit:
        return text
    return text[:limit] + f"\n… [truncated: {len(text) - limit} more chars of {label}; read the full text on GitHub or in the clone]"


def fmt_comment(c: dict) -> str:
    who = c.get("user", {}).get("login", "?")
    if is_claude_post(c):
        who = f"{who} via Claude Code session (an earlier run of you)"
    when = c.get("created_at", "")
    body = quote((c.get("body") or "").strip())
    return f"[{who} · {when}]\n{body}"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--kind", required=True, choices=["DISPATCH", "FOLLOW_UP", "DRY_RUN"])
    ap.add_argument("--issue", required=True, type=int, help="issue or PR number the event belongs to")
    ap.add_argument("--comment-id", type=int, help="FOLLOW_UP: the issue/PR comment that triggered this run")
    ap.add_argument("--review-id", type=int, help="FOLLOW_UP: the PR review that triggered this run")
    ap.add_argument("--repo-root", default=".", help="checkout used to resolve referenced paths")
    ap.add_argument("--max-chars", type=int, default=60000, help="hard cap (API limit is 65,536)")
    ap.add_argument("--run-url", default=os.environ.get("HARNESS_RUN_URL", ""))
    args = ap.parse_args()

    repo = os.environ.get("GH_REPO") or os.environ.get("GITHUB_REPOSITORY")
    if not repo:
        raise SystemExit("GH_REPO (owner/repo) must be set")
    root = Path(args.repo_root).resolve()
    files = repo_files(root)

    issue = gh_json(f"repos/{repo}/issues/{args.issue}")
    is_pr = "pull_request" in issue
    pr = gh_json(f"repos/{repo}/pulls/{args.issue}") if is_pr else None

    comments = gh_json(f"repos/{repo}/issues/{args.issue}/comments?per_page=100", paginate=True)
    harness_comments = [c for c in comments if is_plumbing(c)]
    # Everything else is the conversation: the humans AND earlier Claude sessions (their questions matter).
    human_comments = [c for c in comments if not is_plumbing(c)]
    prior_sessions = []
    for c in harness_comments:
        for m in SESSION_RE.finditer(c.get("body") or ""):
            url = f"https://claude.ai/code/{m.group(1)}"
            if url not in prior_sessions:
                prior_sessions.append(url)

    # Linked issue for a PR: "Closes #N" or the harness marker in the PR body.
    linked_issue = None
    if is_pr:
        body = pr.get("body") or ""
        m = re.search(r"claude-harness[^>]*issue=(\d+)", body) or re.search(r"(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\s+#(\d+)", body, re.I)
        if m:
            linked_issue = int(m.group(1))

    branch = pr["head"]["ref"] if is_pr else f"claude/issue-{args.issue}"
    owner = repo.split("/")[0]
    branch_exists = subprocess.run(["gh", "api", f"repos/{repo}/branches/{branch}"], capture_output=True, text=True).returncode == 0
    branch_prs = gh_json(f"repos/{repo}/pulls?head={owner}:{branch}&state=all&per_page=20") if branch_exists else []

    # Text corpus used for path / doc detection.
    corpus = "\n".join([issue.get("title") or "", issue.get("body") or ""] + [c.get("body") or "" for c in human_comments])

    referenced = []
    by_basename: dict[str, list[str]] = {}
    for f in files:
        by_basename.setdefault(f.rsplit("/", 1)[-1], []).append(f)

    def note(path: str) -> None:
        if path not in referenced:
            referenced.append(path)

    for m in GH_URL_RE.finditer(corpus):
        cand = m.group(1).rstrip("/.,:;")
        if cand in files:
            note(cand)
        elif any(f.startswith(cand + "/") for f in files):
            note(cand + "/")
    corpus_no_urls = GH_URL_RE.sub(" ", corpus)
    for m in PATH_RE.finditer(corpus_no_urls):
        cand = m.group(1).strip("`'\"()[].,:;")
        if cand in files:
            note(cand)
        elif "/" in cand and any(f.startswith(cand.rstrip("/") + "/") for f in files):
            note(cand.rstrip("/") + "/")
        elif "/" not in cand and 1 <= len(by_basename.get(cand, [])) <= 3:
            for f in by_basename[cand]:
                note(f)

    related_docs = list(ALWAYS_INLINE)
    head_text = "\n".join([issue.get("title") or "", issue.get("body") or ""])
    for rx, doc in CONDITIONAL_DOCS:
        if rx.search(head_text) and doc in files and doc not in related_docs:
            related_docs.append(doc)

    # ---- assemble, highest priority first, under the budget -----------------
    budget = args.max_chars - 400  # reserve room for the OMITTED note
    parts: list[str] = []

    def add(section: str) -> bool:
        nonlocal budget
        block = section.rstrip() + "\n\n"
        if len(block) > budget:
            return False
        parts.append(block)
        budget -= len(block)
        return True

    header = [
        "CLAUDE HARNESS PAYLOAD v1",
        f"kind: {args.kind}",
        f"repo: {repo}",
        f"{'pr' if is_pr else 'issue'}: #{args.issue} {issue.get('html_url', '')}",
        f"title: {issue.get('title', '')}",
        f"author: {issue.get('user', {}).get('login', '?')}",
        f"state: {issue.get('state', '')}",
        f"labels: {', '.join(l['name'] for l in issue.get('labels', [])) or '(none)'}",
        f"work_branch: {branch}",
        f"work_branch_exists_on_origin: {'yes — fetch it and continue on top' if branch_exists else 'no — create it from origin/main'}",
    ]
    if branch_prs:
        header.append("prs_for_work_branch: " + ", ".join(
            f"#{q['number']} {'merged' if q.get('merged_at') else q['state']}" for q in branch_prs))
        if any(q["state"] == "open" for q in branch_prs):
            header.append("note: an OPEN pull request already exists for this branch — push to it, do not open another")
        elif all(q["state"] == "closed" and not q.get("merged_at") for q in branch_prs):
            header.append("note: earlier PR(s) for this branch were closed WITHOUT merging — the owner rejected that attempt; read the thread for why before redoing it")
    if is_pr:
        header.append(f"pr_base: {pr['base']['ref']}  pr_head: {pr['head']['ref']}  draft: {pr.get('draft')}")
        if linked_issue:
            header.append(f"linked_issue: #{linked_issue}")
    if prior_sessions:
        header.append("prior_sessions: " + ", ".join(prior_sessions))
    if args.run_url:
        header.append(f"dispatched_by: {args.run_url}")
    add("\n".join(header))

    if args.kind == "DRY_RUN":
        add("--- DRY RUN ---\nThis is a connectivity check. Do exactly what the routine prompt says for DRY_RUN and nothing else.")

    if args.kind == "FOLLOW_UP":
        trig = None
        if args.comment_id:
            trig = gh_json(f"repos/{repo}/issues/comments/{args.comment_id}")
            add("--- TRIGGERING COMMENT (act on this) ---\n" + clip(fmt_comment(trig), 8000, "comment"))
        elif args.review_id and is_pr:
            rev = gh_json(f"repos/{repo}/pulls/{args.issue}/reviews/{args.review_id}")
            rc = gh_json(f"repos/{repo}/pulls/{args.issue}/reviews/{args.review_id}/comments?per_page=100", paginate=True)
            lines = [f"[{rev.get('user', {}).get('login', '?')} · {rev.get('submitted_at', '')} · state={rev.get('state')}]", quote((rev.get("body") or "").strip())]
            for c in rc:
                lines.append(f"\n• {c.get('path')}:{c.get('line') or c.get('original_line')} (review_comment_id={c.get('id')})\n{quote((c.get('body') or '').strip())}")
            add("--- TRIGGERING REVIEW (act on every item) ---\n" + clip("\n".join(lines), 16000, "review"))

    add("--- ISSUE BODY ---\n" + clip(quote((issue.get("body") or "(empty)").strip()), 20000, "issue body"))

    if human_comments:
        text = "\n\n".join(fmt_comment(c) for c in human_comments)
        add(f"--- DISCUSSION ({len(human_comments)} comments, oldest first) ---\n" + clip(text, 16000, "discussion"))

    listed = [d for d in ALWAYS_LIST if d in files]
    add("--- RELATED DOCS ---\n"
        "Inlined below: " + ", ".join(related_docs) + "\n"
        "Read in the clone as needed: " + ", ".join(listed) + "\n"
        "Referenced paths from the thread (exist in repo): " + (", ".join(referenced) or "(none)"))

    if is_pr:
        rcs = gh_json(f"repos/{repo}/pulls/{args.issue}/comments?per_page=100", paginate=True)
        if rcs:
            lines = [f"• {c.get('path')}:{c.get('line') or c.get('original_line')} [{c.get('user', {}).get('login')}] (review_comment_id={c.get('id')})\n{quote((c.get('body') or '').strip())}" for c in rcs]
            add(f"--- ALL PR REVIEW COMMENTS ({len(rcs)}) ---\n" + clip("\n\n".join(lines), 12000, "review comments"))
        if linked_issue:
            li = gh_json(f"repos/{repo}/issues/{linked_issue}")
            add(f"--- LINKED ISSUE #{linked_issue}: {li.get('title', '')} ---\n" + clip(quote((li.get("body") or "").strip()), 8000, "linked issue"))

    # Inline the docs, then referenced markdown specs, while the budget lasts.
    omitted = []
    for doc in related_docs:
        p = root / doc
        if not p.is_file():
            continue
        content = p.read_text(errors="replace")
        if not add(f"--- DOC {doc} ---\n" + clip(content, 14000, doc)):
            omitted.append(doc)
    for ref in referenced:
        if ref.endswith("/") or not ref.endswith((".md", ".txt")):
            continue
        if ref in related_docs:
            continue
        p = root / ref
        if p.is_file():
            content = p.read_text(errors="replace")
            if not add(f"--- SPEC {ref} ---\n" + clip(content, 6000, ref)):
                omitted.append(ref)
    if omitted:
        budget += 400
        add("--- OMITTED FOR SIZE (read in the clone) ---\n" + ", ".join(omitted)[:350])

    sys.stdout.write("".join(parts).rstrip() + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

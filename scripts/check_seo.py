#!/usr/bin/env python3
"""Regression checks for Tokcat public SEO surfaces."""

from __future__ import annotations

import json
import re
from html.parser import HTMLParser
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

REQUIRED_KEYWORDS = [
    "AI token usage monitor",
    "macOS menu bar",
    "Claude Code usage",
    "Codex usage",
    "Cursor usage",
    "LLM cost tracker",
    "AI coding agent usage",
]

README_REQUIRED_PHRASES = [
    "AI token usage monitor for the macOS menu bar",
    "Claude Code usage",
    "Codex usage",
    "Cursor usage",
    "LLM cost tracker",
    "AI coding agent usage",
]

DOCS_REQUIRED_META = {
    "description": [
        "AI token usage monitor",
        "Claude Code usage",
        "Codex usage",
        "Cursor usage",
        "LLM cost tracker",
    ],
    "keywords": REQUIRED_KEYWORDS,
}

REQUIRED_JSONLD_TERMS = [
    "AI token usage monitor",
    "Claude Code usage tracker",
    "Codex usage tracker",
    "Cursor usage tracker",
    "LLM cost tracker",
]

ROOT_INDEX_REQUIRED = [
    "AI token usage monitor",
    "Claude Code usage",
    "Codex usage",
    "Cursor usage",
]


class HeadParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.title = ""
        self._in_title = False
        self.meta: dict[str, str] = {}
        self.jsonld: list[str] = []
        self._in_jsonld = False
        self._jsonld_chunks: list[str] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        attrs_dict = {k: v or "" for k, v in attrs}
        if tag == "title":
            self._in_title = True
        if tag == "meta":
            key = attrs_dict.get("name") or attrs_dict.get("property")
            if key:
                self.meta[key] = attrs_dict.get("content", "")
        if tag == "script" and attrs_dict.get("type") == "application/ld+json":
            self._in_jsonld = True
            self._jsonld_chunks = []

    def handle_endtag(self, tag: str) -> None:
        if tag == "title":
            self._in_title = False
        if tag == "script" and self._in_jsonld:
            self._in_jsonld = False
            self.jsonld.append("".join(self._jsonld_chunks))

    def handle_data(self, data: str) -> None:
        if self._in_title:
            self.title += data
        if self._in_jsonld:
            self._jsonld_chunks.append(data)


def assert_contains(haystack: str, needle: str, label: str) -> None:
    assert needle.lower() in haystack.lower(), f"{label} missing phrase: {needle!r}"


def parse_html(path: str) -> HeadParser:
    parser = HeadParser()
    parser.feed((ROOT / path).read_text(encoding="utf-8"))
    return parser


def test_readme_has_category_search_phrases() -> None:
    text = (ROOT / "README.md").read_text(encoding="utf-8")
    for phrase in README_REQUIRED_PHRASES:
        assert_contains(text, phrase, "README.md")
    assert "## Search phrases" in text or "## Find Tokcat by use case" in text, (
        "README.md should include a use-case/search phrase section"
    )


def test_docs_landing_page_has_search_focused_meta() -> None:
    parser = parse_html("docs/index.html")
    assert "AI Token Usage Monitor" in parser.title, "docs title should target category search"
    for meta_name, phrases in DOCS_REQUIRED_META.items():
        content = parser.meta.get(meta_name, "")
        assert content, f"docs/index.html missing meta {meta_name}"
        for phrase in phrases:
            assert_contains(content, phrase, f"docs meta {meta_name}")


def test_docs_landing_page_jsonld_has_use_case_names() -> None:
    parser = parse_html("docs/index.html")
    assert parser.jsonld, "docs/index.html missing JSON-LD"
    raw = "\n".join(parser.jsonld)
    json.loads(raw)
    for term in REQUIRED_JSONLD_TERMS:
        assert_contains(raw, term, "docs JSON-LD")


def test_root_vite_index_has_basic_share_meta() -> None:
    parser = parse_html("index.html")
    for phrase in ROOT_INDEX_REQUIRED:
        combined = "\n".join([parser.title, *parser.meta.values()])
        assert_contains(combined, phrase, "index.html head")


if __name__ == "__main__":
    tests = [value for name, value in globals().items() if name.startswith("test_")]
    failures = []
    for test in tests:
        try:
            test()
        except Exception as exc:  # noqa: BLE001 - script prints assertion summary
            failures.append((test.__name__, exc))
    if failures:
        for name, exc in failures:
            print(f"FAIL {name}: {exc}")
        raise SystemExit(1)
    print(f"SEO checks passed ({len(tests)} tests)")

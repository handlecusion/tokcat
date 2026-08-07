#!/usr/bin/env python3
"""Generate the Sparkle appcast.xml for a Tokcat release.

Usage:
  make_appcast.py --version 0.2.0 --build 2 \
      --url https://github.com/.../Tokcat_0.2.0_universal.app.tar.gz \
      --ed-signature <sig from sign_update> --length <bytes> \
      [--notes-file notes.md] [--pub-date "Wed, 06 Aug 2026 00:00:00 +0000"] \
      > appcast.xml

Single-item feed: the feed URL uses releases/latest/download/, so each
release ships a fresh appcast describing only itself. Every release MUST
include this file — a release without it 404s Sparkle clients (same rule
as latest.json for legacy Tauri clients).
"""
import argparse
import email.utils
import html
import sys
import time

MINIMUM_SYSTEM_VERSION = "13.0"


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--version", required=True, help="CFBundleShortVersionString")
    p.add_argument("--build", required=True, help="CFBundleVersion (Sparkle compares this)")
    p.add_argument("--url", required=True)
    p.add_argument("--ed-signature", required=True)
    p.add_argument("--length", required=True, type=int)
    p.add_argument("--notes-file")
    p.add_argument("--pub-date", default=email.utils.formatdate(time.time(), usegmt=True))
    args = p.parse_args()

    notes = ""
    if args.notes_file:
        with open(args.notes_file, encoding="utf-8") as f:
            body = html.escape(f.read().strip())
            notes = f"\n      <description><![CDATA[<pre>{body}</pre>]]></description>"

    sys.stdout.write(f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Tokcat</title>
    <item>
      <title>Tokcat {args.version}</title>{notes}
      <pubDate>{args.pub_date}</pubDate>
      <sparkle:version>{args.build}</sparkle:version>
      <sparkle:shortVersionString>{args.version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{MINIMUM_SYSTEM_VERSION}</sparkle:minimumSystemVersion>
      <enclosure url="{html.escape(args.url, quote=True)}"
                 length="{args.length}"
                 type="application/octet-stream"
                 sparkle:edSignature="{args.ed_signature}" />
    </item>
  </channel>
</rss>
""")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Compare a Rust usage_dump JSON against a Swift tokcat-dump JSON.

Usage: parity_normalize.py rust.json swift.json

Rules:
- meta.generatedAt and meta.version are stripped before comparing.
- Objects are compared key-by-key (order-independent).
- Integers must be byte-identical; floats must agree within 1e-6.
- The first divergence is reported with a JSON-path-ish location that
  includes date/client/year hints where available.
"""

import json
import sys

TOL = 1e-6


def strip_meta(doc):
    meta = doc.get("meta")
    if isinstance(meta, dict):
        meta.pop("generatedAt", None)
        meta.pop("version", None)
    return doc


def hint(item):
    if isinstance(item, dict):
        for key in ("date", "client", "year", "modelId"):
            v = item.get(key)
            if isinstance(v, str):
                return f"({key}={v})"
    return ""


def diff(a, b, path):
    if isinstance(a, dict) and isinstance(b, dict):
        for k in sorted(set(a) | set(b)):
            if k not in a:
                return f"{path}.{k}: present only in swift ({b[k]!r})"
            if k not in b:
                return f"{path}.{k}: present only in rust ({a[k]!r})"
            r = diff(a[k], b[k], f"{path}.{k}")
            if r:
                return r
        return None
    if isinstance(a, list) and isinstance(b, list):
        if len(a) != len(b):
            # For lists of dated/keyed dicts, report which entries differ.
            def keys(xs):
                out = []
                for x in xs:
                    if isinstance(x, dict):
                        k = x.get("date") or x.get("year") or (
                            f"{x.get('client')}:{x.get('providerId')}:{x.get('modelId')}"
                            if "client" in x else None)
                        if k:
                            out.append(k)
                return out

            ka, kb = keys(a), keys(b)
            only_rust = [k for k in ka if k not in kb][:5]
            only_swift = [k for k in kb if k not in ka][:5]
            extra = ""
            if only_rust or only_swift:
                extra = f" rust-only={only_rust} swift-only={only_swift}"
            return f"{path}: length {len(a)} (rust) != {len(b)} (swift){extra}"
        for i, (x, y) in enumerate(zip(a, b)):
            r = diff(x, y, f"{path}[{i}]{hint(x)}")
            if r:
                return r
        return None
    if isinstance(a, bool) or isinstance(b, bool):
        return None if a is b else f"{path}: {a!r} != {b!r}"
    if isinstance(a, int) and isinstance(b, int):
        return None if a == b else f"{path}: int {a} (rust) != {b} (swift)"
    if isinstance(a, (int, float)) and isinstance(b, (int, float)):
        if abs(a - b) <= TOL:
            return None
        return f"{path}: float {a} (rust) != {b} (swift), |d|={abs(a - b)}"
    return None if a == b else f"{path}: {a!r} (rust) != {b!r} (swift)"


def main():
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    with open(sys.argv[1]) as f:
        rust = strip_meta(json.load(f))
    with open(sys.argv[2]) as f:
        swift = strip_meta(json.load(f))
    d = diff(rust, swift, "$")
    if d:
        print(f"PARITY MISMATCH: {d}")
        sys.exit(1)
    print("parity OK")


if __name__ == "__main__":
    main()

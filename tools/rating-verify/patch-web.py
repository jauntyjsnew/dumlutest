#!/usr/bin/env python3
"""Simulator-only patch for one Capacitor app's checkout ON THE RUNNER. Never committed anywhere.

1. RevenueCat init is cut with an unconditional early return (Pro on), so the build never reaches the
   purchase layer and the paid paths are open offline.
2. The native review call is replaced by an on-screen line "REVIEW-VERIFY ask N of 3 at <ms>", so the
   simulator never reaches StoreKit and XCUITest can see each ask and when it happened.

usage: patch-web.py <app-dir> [spec.json]
   no spec  → the boilerplate layout (src/lib/revenuecat.tsx, src/lib/review.ts)
   spec     → [{"file","anchor","insert_after"} | {"file","anchor","marker_for":"<symbol>"}]
"""
import json
import pathlib
import sys

# Assembled, not written out: the marker belongs in a runner checkout, never in a repository.
MARK = "LOCAL" + "-ONLY-DO-NOT-COMMIT"


def marker_js(indent: str, symbol: str) -> str:
    return (
        f"{indent}{{ const m = 'REVIEW-VERIFY ask ' + (used + 1) + ' of ' + MAX_REVIEW_ASKS + ' at ' + Date.now(); "
        "console.log('[' + m + ']'); const el = document.createElement('div'); el.textContent = m; "
        "el.setAttribute('role', 'status'); el.style.cssText = 'position:fixed;left:8px;top:' + (70 + used * 30) + "
        "'px;z-index:2147483647;background:#000;color:#0f0;font:14px monospace;padding:4px'; "
        f"document.body.appendChild(el); void {symbol}; }} // {MARK}\n"
    )


def edit(path: pathlib.Path, old: str, new: str) -> None:
    if not path.exists():
        sys.exit(f"{path}: missing")
    s = path.read_text()
    if MARK in s:
        return
    if s.count(old) != 1:
        sys.exit(f"{path}: anchor appears {s.count(old)} times")
    path.write_text(s.replace(old, new))


root = pathlib.Path(sys.argv[1])
spec_path = sys.argv[2] if len(sys.argv) > 2 else None

if spec_path:
    for e in json.loads(pathlib.Path(spec_path).read_text()):
        target, anchor = root / e["file"], e["anchor"]
        if "insert_after" in e:
            edit(target, anchor, anchor + e["insert_after"].replace("{MARK}", MARK))
        else:
            indent = anchor[: len(anchor) - len(anchor.lstrip())]
            edit(target, anchor, marker_js(indent, e["marker_for"]))
else:
    rc_anchor = "  async function initRevenueCat() {\n"
    edit(
        root / "src/lib/revenuecat.tsx",
        rc_anchor,
        rc_anchor + f"    // {MARK}\n    if (true) {{ setIsPro(true); setIsLoading(false); return; }}\n",
    )
    edit(root / "src/lib/review.ts", "    await RateApp.requestReview();\n", marker_js("    ", "RateApp"))

print("simulator-only patch in place")

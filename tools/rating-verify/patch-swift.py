#!/usr/bin/env python3
"""Simulator-only patch for one native SwiftUI (XcodeGen) app's checkout ON THE RUNNER.
Never committed anywhere.

1. PurchaseManager.configure() returns immediately with Pro on: RevenueCat is never configured.
2. Review.swift: the simulator guard is lifted and SKStoreReviewController.requestReview is replaced
   by an on-screen UILabel "REVIEW-VERIFY ask N of 3 at <ms>", so StoreKit is never reached and
   XCUITest can see each ask and when it happened.

usage: patch-swift.py <app-dir>
"""
import pathlib
import sys

MARK = "LOCAL" + "-ONLY-DO-NOT-COMMIT"

MARKER = f"""        // {MARK}: on-screen marker instead of StoreKit (simulator verification)
        do {{
            let n = ReviewPolicy(defaults: .standard).asksUsed + 1
            let text = "REVIEW-VERIFY ask \\(n) of \\(ReviewPolicy.maxAsks) at \\(Int64(Date().timeIntervalSince1970 * 1000))"
            let label = UILabel(frame: CGRect(x: 8, y: 70 + CGFloat(n - 1) * 30, width: 350, height: 24))
            label.text = text
            label.accessibilityLabel = text
            label.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            label.textColor = .green
            label.backgroundColor = .black
            scene.keyWindow?.addSubview(label)
        }}
"""

root = pathlib.Path(sys.argv[1])

review = root / "App/Support/Review.swift"
s = review.read_text()
if MARK not in s:
    guards = [
        "        guard !Telemetry.isSimulator else { return }\n",
        "        guard !runningInSimulator else { return }\n",
    ]
    hits = [g for g in guards if s.count(g) == 1]
    if len(hits) != 1:
        sys.exit("Review.swift: simulator guard not found exactly once")
    s = s.replace(hits[0], f"        // {MARK}: simulator guard lifted, the marker below replaces StoreKit\n")
    call = "        SKStoreReviewController.requestReview(in: scene)\n"
    if s.count(call) != 1:
        sys.exit(f"Review.swift: StoreKit call appears {s.count(call)} times")
    review.write_text(s.replace(call, MARKER))

purchases = root / "App/Support/PurchaseManager.swift"
p = purchases.read_text()
if MARK not in p:
    anchor = "    func configure() {\n"
    if p.count(anchor) != 1:
        sys.exit(f"PurchaseManager.swift: configure() appears {p.count(anchor)} times")
    purchases.write_text(p.replace(anchor, anchor + f"        // {MARK}\n        isPro = true; return\n"))

print("simulator-only patch in place")

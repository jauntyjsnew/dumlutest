// Runner checkout only — never committed into an app. Generic rating-flow check for one Capacitor app,
// driven headlessly. The simulator-only review stub renders "REVIEW-VERIFY ask N of 3 at <ms>" instead
// of calling StoreKit. A presented share sheet hides the page from the accessibility tree, so "not
// while the sheet is up" is proven by clock: each ask's own time must come after the tap that closed
// the sheet. Per-app labels come from the runner environment (xcodebuild TEST_RUNNER_V_*):
//   V_HOME       label prefix of the open-file control on the home screen
//   V_FILE       fixture name prefix in Files › On My iPhone
//   V_READY      label prefix proving the opened file is on screen
//   V_OPEN_ASKS  "1" when a real file on screen is itself a success moment (ask 1), else "0"
//   V_EXPORT     "|"-separated label prefixes tapped to reach the share sheet; "?" marks a step
//                that only appears the first time (skipped when absent)
//   V_ONBOARD    ","-separated onboarding buttons (default Skip,Get Started,Next,Continue)
//   V_CANCEL     "0" to skip the dismissed-sheet round (default runs it)
import XCTest

final class VerifyUITests: XCTestCase {
    private let env = ProcessInfo.processInfo.environment
    private let markerPredicate = NSPredicate(format: "label BEGINSWITH %@", "REVIEW-VERIFY ask")

    override func setUp() {
        continueAfterFailure = true
    }

    func testRatingFlow() throws {
        let home = env["V_HOME"] ?? "", file = env["V_FILE"] ?? "", ready = env["V_READY"] ?? ""
        let openAsks = env["V_OPEN_ASKS"] == "1"
        let steps = (env["V_EXPORT"] ?? "").split(separator: "|").map(String.init)
        XCTAssertFalse(home.isEmpty || file.isEmpty || ready.isEmpty || steps.isEmpty, "runner environment is set")
        let app = XCUIApplication()
        app.launch()
        passOnboarding(app, home: home)
        openFile(app, home: home, name: file)

        XCTAssertTrue(labeled(app, ready).waitForExistence(timeout: 120), "the opened file is on screen (\(ready))")
        let base: Int
        if openAsks {
            XCTAssertTrue(askMarker(app, 1).waitForExistence(timeout: 40), "ask 1 once the real file is on screen")
            base = 1
        } else {
            sleep(6)
            XCTAssertEqual(markers(app).count, 0, "opening the file must not ask")
            base = 0
        }
        snap(app, "opened")

        if env["V_CANCEL"] != "0" {
            XCTAssertTrue(reachSheet(app, steps), "export sheet, cancel round")
            sleep(4)
            snap(app, "sheet-cancel")
            closeSheet(app)
            sleep(10)
            snap(app, "after-cancel")
            XCTAssertEqual(markers(app).count, base, "a sheet closed without sharing must not ask")
        }

        for ask in (base + 1)...4 {
            guard reachSheet(app, steps) else { XCTFail("export sheet \(ask)"); return }
            sleep(4)
            snap(app, "sheet-\(ask)")
            let copy = copyAction(app)
            let tapped = nowMs()
            copy.tap()
            waitGone(copy, 30)
            if ask <= 3 {
                let marker = askMarker(app, ask)
                XCTAssertTrue(marker.waitForExistence(timeout: 30), "ask \(ask) after the sheet closed")
                if marker.exists {
                    XCTAssertGreaterThan(askTime(marker), tapped, "ask \(ask) must come after Copy closed the sheet")
                }
                sleep(3)
            } else {
                sleep(12)
            }
            XCTAssertEqual(markers(app).count, min(ask, 3), "one ask per completed share, none past 3 (\(ask))")
            snap(app, "after-\(ask)")
        }
    }

    // MARK: - Steps

    /// Onboarding first, home second: a slide can carry the home control's words (olmconverter's
    /// "Open .olm archives from Outlook…" vs its "Open .olm archive" button), so home only counts
    /// once no onboarding button is left to tap.
    private func passOnboarding(_ app: XCUIApplication, home: String) {
        let labels = (env["V_ONBOARD"] ?? "Skip,Get Started,Next,Continue").split(separator: ",").map(String.init)
        for step in 0..<14 {
            sleep(2)
            var tapped = false
            for label in labels {
                let b = app.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] %@", label)).firstMatch
                if b.exists && b.isHittable { snap(app, "onboarding-\(step)"); b.tap(); tapped = true; break }
            }
            if tapped { continue }
            let target = element(app, home)
            if target.waitForExistence(timeout: 4) && target.isHittable { break }
        }
        snap(app, "home")
    }

    /// Picks the fixture from Files › On My iPhone. A fresh install's picker may open inside the
    /// app's own (empty) folder, so walk up with the "On My iPhone" back button, or go through
    /// Browse › On My iPhone, until the fixture shows.
    private func openFile(_ app: XCUIApplication, home: String, name: String) {
        XCTAssertTrue(tapIfExists(element(app, home), 20), "open-file control (\(home))")
        let byName = NSPredicate(format: "label BEGINSWITH %@", name)
        let cell = app.cells.matching(byName).firstMatch
        let text = app.staticTexts.matching(byName).firstMatch
        // The picker's own tab bar. The file's name alone cannot tell the picker is gone: the app
        // shows that name once the file is open.
        let pickerTabs = app.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "Browse", "Recents")).firstMatch
        var picked = false
        var tappedFixture = false
        for attempt in 0..<10 {
            sleep(3)
            // "Picker gone" means "picked" only after the fixture was tapped: a picker that never
            // appeared (the open control was missed) is not a pick.
            if tappedFixture && !pickerTabs.exists && !cell.exists { picked = true; break }
            // Icon mode: the name under the thumbnail does not pick the file; the cell's upper part
            // (the thumbnail, or the row in list mode) does. A multi-select picker also needs Open.
            if cell.exists || (text.exists && pickerTabs.exists) {
                if cell.exists {
                    cell.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()
                } else {
                    text.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: -1.5)).tap()
                }
                tappedFixture = true
                sleep(3)
                // Only the PICKER's Open (its navigation bar, while it is up): an app can have its own
                // "Open" tab, and tapping that leaves the file that was just opened.
                let pickerOpen = app.navigationBars.buttons["Open"].firstMatch
                if pickerTabs.exists && pickerOpen.exists && pickerOpen.isEnabled { pickerOpen.tap(); sleep(3) }
                if !pickerTabs.exists && !cell.exists { picked = true; break }
                snap(app, "picker-tapped-\(attempt)")
                continue
            }
            snap(app, "picker-\(attempt)")
            // Already inside On My iPhone: the fixture is further down the grid, so scroll.
            if app.navigationBars.staticTexts["On My iPhone"].exists {
                let files = app.collectionViews["File View"].firstMatch
                if files.exists { files.swipeUp() }
                continue
            }
            // Never a navigation-bar BACK button ("On My iPhone" dismissed a fresh install's picker,
            // "Browse" bounced back out): only the location row, and the tab bar's own Browse tab.
            let location = app.cells.matching(NSPredicate(format: "label BEGINSWITH %@", "On My iPhone")).firstMatch
            if location.exists && location.isHittable { location.tap(); continue }
            let browseTab = app.tabBars.buttons["Browse"].firstMatch
            if browseTab.exists && browseTab.isHittable { browseTab.tap() }
        }
        XCTAssertTrue(picked, "fixture \(name) found in Files › On My iPhone")
        // No trailing "Open" tap: the picker's own Open was handled inside the loop, and after the
        // picker is gone an "Open" button is the app's (fb2-to-pdf's Open tab leaves the book).
        sleep(10)
    }

    /// Taps the export steps in order; true once the share sheet is up. Step prefixes, combinable
    /// in this order: "~" wait for the element without tapping it, "?" optional, "=" exact label,
    /// ">" the right-most button on the same row as the element with that label (an icon-only
    /// button next to a titled one).
    private func reachSheet(_ app: XCUIApplication, _ steps: [String]) -> Bool {
        for raw in steps {
            var label = raw
            let waitOnly = label.hasPrefix("~"); if waitOnly { label.removeFirst() }
            if waitOnly {
                guard element(app, label).waitForExistence(timeout: 300) else { snap(app, "missing-\(label)"); return false }
                continue
            }
            let optional = label.hasPrefix("?"); if optional { label.removeFirst() }
            let exact = label.hasPrefix("="); if exact { label.removeFirst() }
            let rowRight = label.hasPrefix(">"); if rowRight { label.removeFirst() }
            var target = exact ? app.buttons.matching(NSPredicate(format: "label ==[c] %@", label)).firstMatch : element(app, label)
            if rowRight, target.waitForExistence(timeout: optional ? 5 : 180) {
                target = rightmostButton(app, rowOf: target)
            }
            if optional {
                if target.waitForExistence(timeout: 5) {
                    bringIntoView(app, target)
                    if target.isHittable { target.tap(); sleep(2) }
                }
                continue
            }
            guard target.waitForExistence(timeout: 180) else { snap(app, "missing-\(label)"); return false }
            bringIntoView(app, target)
            target.tap()
            sleep(2)
        }
        return copyAction(app).waitForExistence(timeout: 180)
    }

    private func closeSheet(_ app: XCUIApplication) {
        if !tapIfExists(app.buttons["Close"].firstMatch, 6) {
            app.swipeDown()
        }
        waitGone(copyAction(app), 30)
    }

    // MARK: - Queries

    /// Web content below the fold (the SE's short screen) exists but is not hittable: scroll the page
    /// up a little at a time until it is, a handful of times at most.
    private func bringIntoView(_ app: XCUIApplication, _ element: XCUIElement) {
        guard element.exists, !element.isHittable else { return }
        let web = app.webViews.firstMatch
        for _ in 0..<8 {
            if element.isHittable { return }
            if web.exists { web.swipeUp(velocity: .slow) } else { app.swipeUp(velocity: .slow) }
            sleep(1)
        }
    }

    /// The right-most button on the anchor's row, right of the anchor (an icon-only button).
    private func rightmostButton(_ app: XCUIApplication, rowOf anchor: XCUIElement) -> XCUIElement {
        let row = anchor.frame
        var best = anchor
        var bestX = -CGFloat.greatestFiniteMagnitude
        for b in app.buttons.allElementsBoundByIndex {
            let f = b.frame
            guard f.width > 0, abs(f.midY - row.midY) <= max(12, row.height / 2), f.minX >= row.maxX - 1 else { continue }
            if f.minX > bestX { best = b; bestX = f.minX }
        }
        return best
    }

    /// A label from the runner environment: "=text" is a button with exactly that label, anything else
    /// goes through `element` (label starts with the text).
    private func labeled(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        guard label.hasPrefix("=") else { return element(app, label) }
        return app.buttons.matching(NSPredicate(format: "label ==[c] %@", String(label.dropFirst()))).firstMatch
    }

    /// Label matching ignores case: CSS text-transform reaches the accessibility label (olm-viewer's
    /// bottom nav reads "CONVERT", not "Convert").
    /// A button whose label starts with the text, else any element that does (a tappable div's text).
    private func element(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        let predicate = NSPredicate(format: "label BEGINSWITH[c] %@", label)
        let button = app.buttons.matching(predicate).firstMatch
        if button.waitForExistence(timeout: 1) { return button }
        // A big tappable card whose label starts with other words ("OLM to MBOX·PDF·CSV Open .olm
        // archive TAP TO BROWSE FILES"): the button CONTAINING the text, before any inner text.
        let containing = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", label)).firstMatch
        if containing.exists { return containing }
        return app.descendants(matching: .any).matching(predicate).firstMatch
    }

    private func copyAction(_ app: XCUIApplication) -> XCUIElement {
        let types = [XCUIElement.ElementType.button.rawValue, XCUIElement.ElementType.cell.rawValue]
        let predicate = NSPredicate(format: "label == %@ AND (elementType == %lu OR elementType == %lu)", "Copy", types[0], types[1])
        return app.descendants(matching: .any).matching(predicate).firstMatch
    }

    private func markers(_ app: XCUIApplication) -> XCUIElementQuery {
        app.staticTexts.matching(markerPredicate)
    }

    private func askMarker(_ app: XCUIApplication, _ n: Int) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "REVIEW-VERIFY ask \(n) of 3 at ")).firstMatch
    }

    /// The ask's own clock time in ms, from the marker's " at <ms>" suffix (0 when unreadable).
    private func askTime(_ marker: XCUIElement) -> Double {
        Double(marker.label.components(separatedBy: " at ").last ?? "") ?? 0
    }

    private func nowMs() -> Double {
        Date().timeIntervalSince1970 * 1000
    }

    // MARK: - Helpers

    @discardableResult
    private func tapIfExists(_ element: XCUIElement, _ timeout: TimeInterval) -> Bool {
        guard element.waitForExistence(timeout: timeout) else { return false }
        element.tap()
        return true
    }

    private func waitGone(_ element: XCUIElement, _ timeout: TimeInterval) {
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element)
        wait(for: [gone], timeout: timeout)
    }

    private func snap(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        print("VERIFY-TREE \(name) BEGIN\n\(app.debugDescription)\nVERIFY-TREE \(name) END")
    }
}

// Throwaway worktree only — never committed. step-viewer-converter rating flow, driven headlessly.
// A real STEP file opens in the app's NATIVE 3D viewer, presented over the web view; its own Export
// menu writes the file and presents the share sheet, and a completed share reports exportDelivered to
// JS, which asks (Pro, never the demo). The LOCAL-ONLY review stub renders "REVIEW-VERIFY ask N of 3
// at <ms>" in the web page — hidden while the viewer covers it — so every export round runs inside
// the viewer with its tap times recorded, and the asks are read and checked by clock once the viewer
// is closed.
import XCTest

final class VerifyUITests: XCTestCase {
    private let markerPredicate = NSPredicate(format: "label BEGINSWITH %@", "REVIEW-VERIFY ask")

    override func setUp() {
        continueAfterFailure = true
    }

    func testRatingFlow() throws {
        // ⛔ The app's own words stay out of this file: the repository this ships from is PUBLIC and
        // the app is not. They arrive from the runner environment, the way the generic driver gets
        // them — V_HOME the open control, V_FILE the fixture, V_EXPORT the viewer's export button,
        // V_READY the control that proves the native 3D viewer is up.
        let env = ProcessInfo.processInfo.environment
        let home = env["V_HOME"] ?? "", file = env["V_FILE"] ?? ""
        // V_EXPORT is "|"-separated, like the generic driver's: the viewer's export button first,
        // then the format row in the native action sheet it opens.
        let exportSteps = (env["V_EXPORT"] ?? "").split(separator: "|").map(String.init)
        let viewerLabel = env["V_READY"] ?? ""
        XCTAssertFalse(home.isEmpty || file.isEmpty || exportSteps.isEmpty || viewerLabel.isEmpty,
                       "runner environment is set")
        let app = XCUIApplication()
        app.launch()
        passOnboarding(app, home: home)
        openFile(app, home: home, name: file)

        // Not app.buttons[label]: that is an EXACT match on a BUTTON, and these controls are often
        // icon buttons whose only text is a title attribute, or tappable non-buttons inside a web
        // view. Measured on stlviewer: nothing in the accessibility tree was labelled "Export" at
        // all, and the same shape is what this app fails on. element() matches a label prefix and
        // falls through to any descendant.
        let exportButton = element(app, exportSteps.first ?? "")
        let closeViewer = element(app, viewerLabel)
        XCTAssertTrue(closeViewer.waitForExistence(timeout: 240), "the native 3D viewer is presented")
        XCTAssertTrue(exportButton.waitForExistence(timeout: 30), "the viewer's Export button")
        sleep(6)
        snap(app, "viewer")
        let openedAt = nowMs()

        // Dismissed at the sheet: no ask.
        XCTAssertTrue(reachSheet(app, exportSteps), "export sheet, cancel round")
        sleep(4)
        snap(app, "sheet-cancel")
        closeSheet(app)
        sleep(8)
        let cancelledAt = nowMs()

        var copiedAt: [Int: Double] = [:]
        for round in 2...4 {
            guard reachSheet(app, exportSteps) else { XCTFail("export sheet \(round)"); break }
            sleep(4)
            snap(app, "sheet-\(round)")
            let copy = copyAction(app)
            copiedAt[round] = nowMs()
            copy.tap()
            waitGone(copy, 30)
            sleep(8)
            snap(app, "after-\(round)")
        }

        XCTAssertTrue(tapIfExists(closeViewer, 20), "close the viewer")
        sleep(6)
        snap(app, "closed")
        let times = (1...3).map { askTime(askMarker(app, $0)) }
        XCTAssertEqual(markers(app).count, 3, "open + two completed shares ask; the dismissed sheet and the 4th share do not")
        XCTAssertGreaterThan(times[0], 0, "ask 1 present")
        XCTAssertLessThan(times[0], openedAt + 1, "ask 1 came when the real model was on screen, before any export")
        if let c2 = copiedAt[2] { XCTAssertGreaterThan(times[1], max(c2, cancelledAt), "ask 2 came after Copy closed sheet 2 — not at the dismissed sheet") }
        if let c3 = copiedAt[3] { XCTAssertGreaterThan(times[2], c3, "ask 3 came after Copy closed sheet 3") }
        if let c4 = copiedAt[4] { XCTAssertLessThan(times[2], c4, "nothing asked for the 4th share (ask 3 predates it)") }
    }

    // MARK: - Steps

    /// Onboarding first, home second: a slide can carry the home control's words, so home only
    /// counts once no onboarding button is left to tap.
    private func passOnboarding(_ app: XCUIApplication, home: String) {
        for step in 0..<14 {
            sleep(2)
            var tapped = false
            for label in ["Skip", "Get Started", "Continue", "Next"] {
                let b = app.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] %@", label)).firstMatch
                if b.exists && b.isHittable { snap(app, "onboarding-\(step)"); b.tap(); tapped = true; break }
            }
            if tapped { continue }
            let target = element(app, home)
            if target.waitForExistence(timeout: 4) && target.isHittable { break }
        }
        snap(app, "home")
    }

    /// Picks the fixture (copied into the fresh install's Documents, where the picker opens).
    private func openFile(_ app: XCUIApplication, home: String, name: String) {
        // The configured words first; if they are not on this screen, fall back to the biggest
        // tappable thing rather than failing the whole run on one label that may have changed.
        var opener = element(app, home)
        if !(opener.waitForExistence(timeout: 20) && opener.isHittable), let big = openCandidates(app).first {
            let f = big.frame
            print("VERIFY-STATE fallback=largest-card at (\(Int(f.minX)),\(Int(f.minY))) "
                  + "size \(Int(f.width))x\(Int(f.height))")
            opener = big
        }
        XCTAssertTrue(tapIfExists(opener, 20), "open-file control (\(home))")
        let byName = NSPredicate(format: "label BEGINSWITH %@", name)
        let cell = app.cells.matching(byName).firstMatch
        let text = app.staticTexts.matching(byName).firstMatch
        // The picker's own tab bar: the file's name alone cannot tell the picker is gone.
        let pickerTabs = app.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "Browse", "Recents")).firstMatch
        var picked = false
        var tappedFixture = false
        for attempt in 0..<10 {
            sleep(3)
            // Same rules the generic driver had to learn, ported here: "the picker is gone" must be
            // judged by the picker's OWN furniture — its tabs and its title — because the app lists
            // the file it just opened as a row of its own, so that row never disappears.
            let pickerUp = pickerTabs.exists || app.navigationBars.staticTexts["On My iPhone"].exists
            if !pickerUp && (tappedFixture || text.exists) { picked = true; break }
            // Only tap what is still on screen: a row that vanished between the poll and the tap makes
            // XCUITest fail on the coordinate itself, which reads like a test error.
            if (cell.exists && cell.isHittable) || (text.exists && pickerTabs.exists) {
                // One gesture does not open the file in every picker: a list row opens on a single
                // tap, a grid tile only selects and needs Open, and some want the thumbnail rather
                // than the row's middle. Escalate across attempts instead of repeating one tap.
                if cell.exists && cell.isHittable {
                    let spot = cell.coordinate(withNormalizedOffset:
                        CGVector(dx: 0.5, dy: attempt % 3 == 1 ? 0.5 : 0.25))
                    if attempt % 3 == 2 { spot.doubleTap() } else { spot.tap() }
                } else if text.exists {
                    text.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: -1.5)).tap()
                }
                tappedFixture = true
                sleep(3)
                // The picker's own Open — navigation bar OR toolbar; in grid mode a tap only selects.
                // Never a TAB bar button: an app can have an "Open" tab and tapping it leaves the file.
                for bar in [app.navigationBars, app.toolbars] {
                    let open = bar.buttons["Open"].firstMatch
                    if pickerTabs.exists && open.exists && open.isEnabled { open.tap(); sleep(3); break }
                }
                if !pickerTabs.exists && !app.navigationBars.staticTexts["On My iPhone"].exists {
                    picked = true
                    break
                }
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
            // Never a navigation-bar BACK button: only the location row and the tab bar's Browse tab.
            let location = app.cells.matching(NSPredicate(format: "label BEGINSWITH %@", "On My iPhone")).firstMatch
            if location.exists && location.isHittable { location.tap(); continue }
            let browseTab = app.tabBars.buttons["Browse"].firstMatch
            if browseTab.exists && browseTab.isHittable { browseTab.tap() }
        }
        XCTAssertTrue(picked, "fixture \(name) picked")
    }

    /// Taps the export steps in order — the viewer's export button, then the format row in the native
    /// action sheet it opens — and is true once the share sheet is up. Every label comes from the
    /// runner environment; none of the app's words live in this file.
    private func reachSheet(_ app: XCUIApplication, _ steps: [String]) -> Bool {
        for (i, label) in steps.enumerated() {
            guard tapIfExists(element(app, label), i == 0 ? 30 : 15) else {
                snap(app, "no-export-step-\(i)")
                return false
            }
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

    /// Things that could be the open-file control, biggest first — the same search the generic driver
    /// had to grow: the control can sit at the BOTTOM of the screen, it can be small, and it is not
    /// always a button (a tappable card in a web view can report as plain text).
    private func openCandidates(_ app: XCUIApplication) -> [XCUIElement] {
        let tabBarTop = app.tabBars.firstMatch.exists ? app.tabBars.firstMatch.frame.minY : .greatestFiniteMagnitude
        func usable(_ e: XCUIElement) -> Bool {
            guard e.exists, e.isHittable else { return false }
            let f = e.frame
            return f.width * f.height > 1200 && f.midY < tabBarTop
        }
        let area: (XCUIElement) -> CGFloat = { $0.frame.width * $0.frame.height }
        let buttons = app.buttons.allElementsBoundByIndex.filter(usable).sorted { area($0) > area($1) }
        let others = (app.otherElements.allElementsBoundByIndex + app.staticTexts.allElementsBoundByIndex)
            .filter(usable).sorted { area($0) > area($1) }
        return buttons + others
    }

    private func element(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        let predicate = NSPredicate(format: "label BEGINSWITH %@", label)
        let button = app.buttons.matching(predicate).firstMatch
        if button.waitForExistence(timeout: 1) { return button }
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

    /// The ask's own clock time in ms, from the marker's " at <ms>" suffix (0 when absent).
    private func askTime(_ marker: XCUIElement) -> Double {
        guard marker.exists else { return 0 }
        return Double(marker.label.components(separatedBy: " at ").last ?? "") ?? 0
    }

    private func nowMs() -> Double {
        Date().timeIntervalSince1970 * 1000
    }

    // MARK: - Helpers

    @discardableResult
    private func tapIfExists(_ element: XCUIElement, _ timeout: TimeInterval) -> Bool {
        guard element.waitForExistence(timeout: timeout) else { return false }
        // Same lesson the generic driver paid for: a card can be on screen and enabled yet report
        // "not hittable" (a web view answers hit testing for its own content). `tap()` then fails the
        // whole test — with XCUITest quoting the app's label into a public log — and tapping the
        // element's own coordinate space does not reach the page either. A tap on the APPLICATION at
        // that absolute point is a real screen touch, and the web view gets it.
        if element.isHittable {
            element.tap()
        } else {
            let f = element.frame
            XCUIApplication().coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: f.midX, dy: f.midY))
                .tap()
        }
        return true
    }

    private func waitGone(_ element: XCUIElement, _ timeout: TimeInterval) {
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element)
        wait(for: [gone], timeout: timeout)
    }

    private func snap(_ app: XCUIApplication, _ name: String) {
        // No screenshot attachment. Nothing ever reads the .xcresult here, and on a loaded runner
        // `app.screenshot()` times out ("Failed to get screenshot") — which fails the test for a
        // reason that has nothing to do with the rating policy. The tree below is what the step
        // breadcrumbs are built from, and it goes to the log file, never to the public console.
        print("VERIFY-TREE \(name) BEGIN\n\(app.debugDescription)\nVERIFY-TREE \(name) END")
    }
}

import XCTest

/// End-to-end against a REAL nodeterm Server Edition instance on http://127.0.0.1:8444
/// (seeded with project "Sim Test" + terminal node "Sim Shell"; password below).
/// Proves: Add Server UI -> POST /auth/login -> WS upgrade -> workspace:load -> session row
/// -> terminal co-attach (pty:create join). Server-side evidence: tmux session nt-simnode1.
final class ConnectFlowUITests: XCTestCase {
    @MainActor
    func testAddServerLoginAndOpenTerminal() throws {
        let app = XCUIApplication()
        app.launch()

        app.buttons["Add Server"].firstMatch.tap()

        let name = app.textFields["Name"]
        XCTAssertTrue(name.waitForExistence(timeout: 10), "Add Server form should open")
        name.tap(); name.typeText("SimTest")

        let url = app.textFields["Base URL (https://…)"]
        url.tap()
        // The field is pre-filled "https://" — clear it before typing the test URL.
        if let existing = url.value as? String, !existing.isEmpty, existing != url.placeholderValue {
            url.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count + 2))
        }
        url.typeText("http://127.0.0.1:8444")

        // Tap the INNER switch control — tapping the labeled row doesn't toggle it.
        let insecureRow = app.switches["Allow insecure http (localhost only)"]
        let control = insecureRow.switches.firstMatch
        (control.exists ? control : insecureRow).tap()
        XCTAssertEqual((insecureRow.value as? String), "1", "insecure-http toggle must be ON")

        let pw = app.secureTextFields.firstMatch
        pw.tap(); pw.typeText("simtest-pass-8444")

        app.buttons["Connect"].firstMatch.tap()

        // iOS may float a "Save Password?" autofill alert over the app — it eats every tap
        // until dismissed (this is what broke the first runs of this test).
        let notNow = app.buttons["Not Now"]
        if notNow.waitForExistence(timeout: 4) { notNow.tap() }

        // Login + WS + workspace:load must surface the seeded session row on HOME.
        let row = app.staticTexts["Sim Shell"]
        XCTAssertTrue(row.waitForExistence(timeout: 20),
                      "session row should appear after login + workspace:load")

        // Server list should show the profile as online (not the offline/sign-in state).
        XCTAssertFalse(app.staticTexts["Sign in"].firstMatch.exists,
                       "server must not be in auth-required state")

        // Open the terminal: this fires pty:create (co-attach/spawn) on the server.
        // SwiftUI list rows can report non-hittable while visible — tap by coordinate instead.
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        // Terminal screen: wait for the attach, then assert it did not land in an error phase.
        sleep(6)
        XCTAssertFalse(app.staticTexts["Welcome back"].isHittable,
                       "terminal screen should be presented after tapping the session")
        for bad in ["Couldn't attach", "No session", "Session closed"] {
            XCTAssertFalse(app.staticTexts[bad].exists, "terminal must not show error: \(bad)")
        }

        // Liveness proof: type a command into the terminal; the host-side test harness verifies
        // /tmp/nt-sim-e2e-proof appears (input path -> pty:write -> tmux -> shell).
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap()
        sleep(1)
        app.typeText("touch /tmp/nt-sim-e2e-proof\n")
        sleep(3)

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "final-terminal"; shot.lifetime = .keepAlways
        add(shot)
    }
}

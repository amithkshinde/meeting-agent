import XCTest
@testable import MeetingAgent

final class SummaryGuardTests: XCTestCase {
    let transcript = "[00:10] Them: We need to fix the login screen layout and the button colours before Friday."

    func testBulletNotInTranscriptIsDropped() {
        let summary = "## Summary\nThey talked about the login screen.\n\n## Discussion\n- Login screen layout and button colours need fixing before Friday\n- Automatic GPS tracking with PDF and CSV reports for vehicles"
        let result = SummaryGuard.clean(summary, transcript: transcript)
        XCTAssertEqual(result.dropped, 1)
        XCTAssertFalse(result.text.contains("GPS"))
        XCTAssertTrue(result.text.contains("Login screen layout"))
    }

    func testDuplicateHeadingsAndBulletsAreRemoved() {
        let summary = "## Discussion\n- Login screen layout needs fixing\n\n## By screen\n### Screen 1\n- Button colours need fixing\n\n## By screen\n### Screen 1\n- Button colours need fixing\n\n## Decisions\n- Login screen layout needs fixing"
        let result = SummaryGuard.clean(summary, transcript: transcript)
        XCTAssertEqual(result.text.components(separatedBy: "## By screen").count - 1, 1)
        XCTAssertEqual(result.text.components(separatedBy: "Login screen layout needs fixing").count - 1, 1)
        XCTAssertTrue(result.text.contains("None."))
    }

    func testAttendeesIgnoreNoiseAndFoldFirstNames() {
        let text = "[00:01] Rahul: hi\n[00:02] Rahul Raju: hello\n[00:03] Bish®: x\n[00:04] Speaker 1: y"
        let who = CallProcessor.attendees(in: text, you: "Amith")
        XCTAssertEqual(who, ["Amith (You)", "Rahul Raju", "Speaker 1"])
    }

    func testMeaningfulScreensIgnoreQuickChanges() {
        let shots = [3.0, 11.0, 457.0].map { ScreenShot(id: 0, t: $0, file: "x.jpg") }
        XCTAssertEqual(ScreenIndex.meaningful(shots).map { $0.t }, [3.0, 457.0])
    }
}

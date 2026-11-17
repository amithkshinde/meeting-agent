import XCTest
@testable import MeetingAgent

final class ReliabilityTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1000)

    func testRedactorHidesKeysEmailsAndAccountName() {
        XCTAssertTrue(Redactor.clean("key AIzaSyA1234567890abcdefghijkl end").contains("[key]"))
        XCTAssertFalse(Redactor.clean("mail amith@example.com now").contains("@"))
        XCTAssertEqual(Redactor.clean("/Users/amith/Movies/x"), "/Users/~/Movies/x")
    }

    func testWrapUpWaitsThenStops() {
        var wrap = WrapUp()
        XCTAssertEqual(wrap.update(now: t0, callIsLive: false, lastSound: nil, keepPressed: false), .warn(secondsLeft: 45))
        XCTAssertEqual(wrap.update(now: t0.addingTimeInterval(30), callIsLive: false, lastSound: nil, keepPressed: false), .warn(secondsLeft: 15))
        XCTAssertEqual(wrap.update(now: t0.addingTimeInterval(46), callIsLive: false, lastSound: nil, keepPressed: false), .stop(.callEnded))
    }

    func testWrapUpCancelsWhenCallComesBackOrSoundContinues() {
        var wrap = WrapUp()
        _ = wrap.update(now: t0, callIsLive: false, lastSound: nil, keepPressed: false)
        XCTAssertEqual(wrap.update(now: t0.addingTimeInterval(10), callIsLive: true, lastSound: nil, keepPressed: false), .carryOn)
        XCTAssertFalse(wrap.isWrappingUp)
        XCTAssertEqual(wrap.update(now: t0.addingTimeInterval(50), callIsLive: false, lastSound: t0.addingTimeInterval(45), keepPressed: false), .carryOn)
    }

    func testWrapUpNeverWaitsForeverBecauseOfSound() {
        var wrap = WrapUp()
        _ = wrap.update(now: t0, callIsLive: false, lastSound: t0, keepPressed: false)
        XCTAssertEqual(wrap.update(now: t0.addingTimeInterval(301), callIsLive: false, lastSound: t0.addingTimeInterval(300), keepPressed: false), .stop(.callEnded))
    }

    func testLedgerCountsFailures() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-\(UUID().uuidString).json")
        let ledger = RecordingLedger(url: url)
        let now = Date()
        ledger.begin(LedgerEntry(id: "a", app: "Google Meet", startedAt: now.addingTimeInterval(-600), automatic: true))
        ledger.begin(LedgerEntry(id: "b", app: "Zoom", startedAt: now.addingTimeInterval(-300), automatic: false))
        ledger.finish(id: "a", reason: .streamError, at: now.addingTimeInterval(-500))
        XCTAssertEqual(ledger.failures(inLastDays: 7, now: now).count, 1)
        XCTAssertEqual(ledger.closeOpenAsCrashed(at: now).count, 1)
        XCTAssertEqual(RecordingLedger(url: url).entries.count, 2)
    }

    func testStallOnlyAfterAudioStopsArriving() {
        let tracker = ActivityTracker()
        tracker.reset(now: t0)
        XCTAssertNil(tracker.stall(now: t0.addingTimeInterval(40)))
        tracker.note(.mic, rms: 0.1, at: t0.addingTimeInterval(28))
        XCTAssertNil(tracker.stall(now: t0.addingTimeInterval(40)))
        XCTAssertNotNil(tracker.stall(now: t0.addingTimeInterval(70)))
    }

    func testDiskGuard() {
        XCTAssertEqual(DiskGuard.verdict(freeBytes: 500_000_000), .critical(500_000_000))
        XCTAssertEqual(DiskGuard.verdict(freeBytes: 50_000_000_000), .fine)
    }

    func testResumeOnlyAfterSystemInterruptions() {
        let policy = ResumePolicy()
        XCTAssertTrue(policy.shouldResume(reason: .streamError, resumesSoFar: 0, callStillLive: true, wasStoppedByUser: false))
        XCTAssertFalse(policy.shouldResume(reason: .streamError, resumesSoFar: 3, callStillLive: true, wasStoppedByUser: false))
        XCTAssertFalse(policy.shouldResume(reason: .sleep, resumesSoFar: 0, callStillLive: true, wasStoppedByUser: false))
    }

    func testLogRotationKeepsFilesBounded() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("log-\(UUID().uuidString)")
        let file = RotatingFile(url: dir.appendingPathComponent("a.log"), maxBytes: 200, keep: 2)
        for i in 0..<30 { file.append("line number \(i) with some padding\n") }
        XCTAssertEqual(file.allFiles.count, 3)
        XCTAssertTrue(file.tail(maxChars: 100_000).contains("line number 29"))
    }

    func testCleanExitMarker() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("marker-\(UUID().uuidString)")
        XCTAssertNil(SessionMarker.begin(at: url, version: "1.0"))
        XCTAssertEqual(SessionMarker.begin(at: url, version: "1.1")?.version, "1.0")
        SessionMarker.end(at: url)
        XCTAssertNil(SessionMarker.begin(at: url, version: "1.2"))
    }
}

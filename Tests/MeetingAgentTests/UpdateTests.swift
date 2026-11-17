import XCTest
@testable import MeetingAgent

final class UpdateTests: XCTestCase {
    func testVersionOrdering() {
        XCTAssertTrue(AppVersion("v1.10.0")! > AppVersion("1.9.9")!)
        XCTAssertEqual(AppVersion("0.2"), AppVersion("0.2.0"))
        XCTAssertNil(AppVersion("abc"))
    }

    func testPicksTheInstallerForThisChip() {
        let json = """
        {"tag_name":"v0.3.0","body":"## What's new\\n- Faster","assets":[
        {"name":"MeetingAgent-0.3.0-arm64.dmg","browser_download_url":"https://example.com/a.dmg"},
        {"name":"MeetingAgent-0.3.0-intel.dmg","browser_download_url":"https://example.com/i.dmg"}]}
        """
        let release = ReleaseInfo.parse(Data(json.utf8))
        XCTAssertEqual(release?.installer(appleSilicon: true)?.lastPathComponent, "a.dmg")
        XCTAssertEqual(release?.installer(appleSilicon: false)?.lastPathComponent, "i.dmg")
        XCTAssertEqual(release?.headline, "What's new")
    }

    func testOnlyNewerVersionsNotify() {
        XCTAssertTrue(UpdateDecision.isNewer(latest: "v0.3.0", installed: "0.2.0"))
        XCTAssertFalse(UpdateDecision.isNewer(latest: "v0.2.0", installed: "0.2.0"))
        XCTAssertFalse(UpdateDecision.isNewer(latest: "nonsense", installed: "0.2.0"))
    }
}

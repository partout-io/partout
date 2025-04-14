import PartoutCore
import XCTest

final class PartoutCoreTests: XCTestCase {
    func test_dummy() {
        var profile = Profile.Builder(activatingModules: true)
        profile.name = "foobar"
        XCTAssertEqual(profile.name, "foobar")
    }
}

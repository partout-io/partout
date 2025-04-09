import Partout
import XCTest

final class PartoutTests: XCTestCase {
    func test_dummy() {
        var profile = Profile.Builder(activatingModules: true)
        profile.name = "foobar"
        XCTAssertEqual(profile.name, "foobar")
    }
}

import XCTest
@testable import Pass

final class ProjectAgentIdentityTests: XCTestCase {
    func testOneStableManagerPerProject() {
        let first = "/repos/first"
        let second = "/repos/second"
        let name = ProjectAgentIdentity.sessionName(for: first)

        XCTAssertEqual(name, ProjectAgentIdentity.sessionName(for: first))
        XCTAssertNotEqual(name, ProjectAgentIdentity.sessionName(for: second))
        XCTAssertTrue(ProjectAgentIdentity.isManager(name: name, projectRoot: first))
        XCTAssertFalse(ProjectAgentIdentity.isManager(name: name, projectRoot: second))
        XCTAssertFalse(ProjectAgentIdentity.isManager(name: "pass-first", projectRoot: first))
        XCTAssertNotEqual(ProjectAgentIdentity.piSessionID(for: first),
                          ProjectAgentIdentity.piSessionID(for: second))
    }
}

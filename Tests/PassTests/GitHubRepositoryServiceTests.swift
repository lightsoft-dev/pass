import XCTest
@testable import Pass

final class GitHubRepositoryServiceTests: XCTestCase {
    func testLoadsAccessibleRepositoriesAndUsesConfiguredSSHProtocol() throws {
        let snapshot = try GitHubRepositoryService.load(executable: "/usr/local/bin/gh") { _, arguments in
            if arguments == ["api", "user"] {
                return result(#"{"login":"mina","name":"Mina Park"}"#)
            }
            if arguments == ["config", "get", "git_protocol", "-h", "github.com"] {
                return result("ssh\n")
            }
            XCTAssertEqual(arguments, [
                "api", "--paginate", "--slurp", "-X", "GET", "user/repos",
                "-f", "per_page=100",
                "-f", "affiliation=owner,collaborator,organization_member",
                "-f", "sort=pushed",
                "-f", "direction=desc",
            ])
            return result(repositoryPages)
        }

        XCTAssertEqual(snapshot.account, GitHubAccount(login: "mina", name: "Mina Park"))
        XCTAssertEqual(snapshot.repositories.count, 2)
        XCTAssertEqual(snapshot.repositories[0].fullName, "mina/private-tool")
        XCTAssertEqual(snapshot.repositories[0].cloneURL, "git@github.com:mina/private-tool.git")
        XCTAssertTrue(snapshot.repositories[0].isPrivate)
        XCTAssertEqual(snapshot.repositories[0].permission, "admin")
        XCTAssertEqual(snapshot.repositories[1].permission, "read")
    }

    func testDefaultsToHTTPSWhenGitProtocolCannotBeRead() throws {
        let repositories = try GitHubRepositoryService.repositories(
            executable: "/usr/local/bin/gh",
            run: { _, arguments in
                if arguments.first == "config" {
                    return result("", stderr: "not configured", code: 1)
                }
                return result(repositoryPages)
            }
        )

        XCTAssertEqual(repositories[0].cloneURL, "https://github.com/mina/private-tool.git")
    }

    func testReportsSignedOutGitHubCLI() {
        XCTAssertThrowsError(try GitHubRepositoryService.account(
            executable: "/usr/local/bin/gh",
            run: { _, _ in result("", stderr: "To get started with GitHub CLI, run: gh auth login", code: 4) }
        )) { error in
            XCTAssertEqual(error as? GitHubRepositoryService.Failure, .signedOut)
        }
    }

    func testReportsExpiredCredentialAsSignedOut() {
        XCTAssertThrowsError(try GitHubRepositoryService.account(
            executable: "/usr/local/bin/gh",
            run: { _, _ in result("", stderr: "gh: Bad credentials (HTTP 401)", code: 1) }
        )) { error in
            XCTAssertEqual(error as? GitHubRepositoryService.Failure, .signedOut)
        }
    }

    func testReportsMissingGitHubCLI() {
        XCTAssertThrowsError(try GitHubRepositoryService.load(executable: nil)) { error in
            XCTAssertEqual(error as? GitHubRepositoryService.Failure, .cliUnavailable)
        }
    }

    private func result(_ stdout: String, stderr: String = "", code: Int32 = 0) -> ProcResult {
        ProcResult(stdout: stdout, stderr: stderr, code: code)
    }

    private var repositoryPages: String {
        #"""
        [[{
          "id": 101,
          "owner": {"login": "mina"},
          "name": "private-tool",
          "full_name": "mina/private-tool",
          "description": "A private utility",
          "clone_url": "https://github.com/mina/private-tool.git",
          "ssh_url": "git@github.com:mina/private-tool.git",
          "private": true,
          "archived": false,
          "fork": false,
          "pushed_at": "2026-08-07T01:00:00Z",
          "permissions": {"admin": true, "maintain": true, "push": true, "triage": true, "pull": true}
        }], [{
          "id": 202,
          "owner": {"login": "lightsoft-dev"},
          "name": "shared-library",
          "full_name": "lightsoft-dev/shared-library",
          "description": null,
          "clone_url": "https://github.com/lightsoft-dev/shared-library.git",
          "ssh_url": "git@github.com:lightsoft-dev/shared-library.git",
          "private": false,
          "archived": false,
          "fork": true,
          "pushed_at": null,
          "permissions": {"admin": false, "maintain": false, "push": false, "triage": false, "pull": true}
        }]]
        """#
    }
}

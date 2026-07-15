import XCTest
@testable import Pass

final class ProjectExportServiceTests: XCTestCase {
    /// Sandbox holding the fake project folders and the produced archives.
    private var tmp: String!

    override func setUpWithError() throws {
        let dir = NSTemporaryDirectory() + "pass-export-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        // Canonicalize (/var → /private/var) so paths match what git rev-parse reports.
        tmp = URL(fileURLWithPath: dir).resolvingSymlinksInPath().path
    }

    override func tearDownWithError() throws {
        if let tmp { try? FileManager.default.removeItem(atPath: tmp) }
    }

    // MARK: End-to-end (real git/rsync/tar subprocesses)

    func testArchivesNonRemoteRepoAndExcludesNodeModules() throws {
        let repo = try makeGitRepo("localonly", remote: nil,
                                   extras: [("node_modules/big.js", "x"), ("src/main.swift", "y")])
        let out = URL(fileURLWithPath: tmp + "/backup.tar.gz")

        let result = ProjectExportService.export(
            projects: [Project(rootPath: repo)],
            options: .init(optimizeGitRepos: true), to: out)

        guard case .success(let s) = result else { return XCTFail("expected success, got \(result)") }
        XCTAssertEqual(s.archived, 1)
        XCTAssertEqual(s.linkedByURL, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path))
        XCTAssertGreaterThan(s.bytes, 0)

        let list = tarList(out)
        XCTAssertTrue(list.contains { $0.hasSuffix("manifest.json") })
        XCTAssertTrue(list.contains { $0.hasSuffix("restore.sh") })
        XCTAssertTrue(list.contains { $0.hasSuffix("projects/localonly/src/main.swift") })
        // node_modules is a build artifact — must be excluded from the archive.
        XCTAssertFalse(list.contains { $0.contains("node_modules") })
    }

    func testLinksRemoteRepoByURL() throws {
        let repo = try makeGitRepo("hasremote", remote: "git@github.com:me/hasremote.git")
        let out = URL(fileURLWithPath: tmp + "/backup2.tar.gz")

        let result = ProjectExportService.export(
            projects: [Project(rootPath: repo)],
            options: .init(optimizeGitRepos: true), to: out)

        guard case .success(let s) = result else { return XCTFail("expected success, got \(result)") }
        XCTAssertEqual(s.linkedByURL, 1)
        XCTAssertEqual(s.archived, 0)

        // A linked repo's folder is NOT copied into the bundle.
        XCTAssertFalse(tarList(out).contains { $0.contains("projects/hasremote/") })

        // Manifest records it as gitRemote with the remote URL + commit.
        let manifest = try readManifest(out)
        let entry = manifest.projects.first { $0.name == "hasremote" }
        XCTAssertEqual(entry?.mode, .gitRemote)
        XCTAssertEqual(entry?.git?.remoteURL, "git@github.com:me/hasremote.git")
        XCTAssertEqual(entry?.git?.commit.isEmpty, false)
    }

    func testOptimizeOffArchivesRemoteRepo() throws {
        let repo = try makeGitRepo("hasremote", remote: "git@github.com:me/x.git")
        let out = URL(fileURLWithPath: tmp + "/backup3.tar.gz")

        let result = ProjectExportService.export(
            projects: [Project(rootPath: repo)],
            options: .init(optimizeGitRepos: false), to: out)

        guard case .success(let s) = result else { return XCTFail("expected success, got \(result)") }
        // Optimize off → folder copied even though the repo has a remote.
        XCTAssertEqual(s.archived, 1)
        XCTAssertEqual(s.linkedByURL, 0)
        XCTAssertTrue(tarList(out).contains { $0.hasSuffix("projects/hasremote/README") })
    }

    func testArchivesPlainNonGitFolder() throws {
        let plain = tmp + "/notes"
        try FileManager.default.createDirectory(atPath: plain, withIntermediateDirectories: true)
        try "todo".write(toFile: plain + "/todo.md", atomically: true, encoding: .utf8)
        let out = URL(fileURLWithPath: tmp + "/backup4.tar.gz")

        let result = ProjectExportService.export(
            projects: [Project(rootPath: plain)],
            options: .init(optimizeGitRepos: true), to: out)

        guard case .success(let s) = result else { return XCTFail("expected success, got \(result)") }
        XCTAssertEqual(s.archived, 1)
        XCTAssertTrue(tarList(out).contains { $0.hasSuffix("projects/notes/todo.md") })
    }

    func testEmptyProjectListFails() {
        let out = URL(fileURLWithPath: tmp + "/empty.tar.gz")
        if case .success = ProjectExportService.export(
            projects: [], options: .init(optimizeGitRepos: true), to: out) {
            XCTFail("empty project list should fail")
        }
    }

    // MARK: Pure helpers (no subprocess)

    func testModeDecision() {
        XCTAssertEqual(ProjectExportService.mode(hasRemote: true,  isGitRepo: true,  optimize: true),  .gitRemote)
        XCTAssertEqual(ProjectExportService.mode(hasRemote: true,  isGitRepo: true,  optimize: false), .archive)
        XCTAssertEqual(ProjectExportService.mode(hasRemote: false, isGitRepo: true,  optimize: true),  .archive)
        XCTAssertEqual(ProjectExportService.mode(hasRemote: true,  isGitRepo: false, optimize: true),  .archive)
    }

    func testUniqueNameDisambiguates() {
        var used = Set<String>()
        XCTAssertEqual(ProjectExportService.uniqueName("web", in: &used), "web")
        XCTAssertEqual(ProjectExportService.uniqueName("web", in: &used), "web-2")
        XCTAssertEqual(ProjectExportService.uniqueName("web", in: &used), "web-3")
    }

    func testRestoreScriptHasBlockPerProject() {
        let entries = [
            ManifestProject(name: "a", originalPath: "/x/a", emoji: nil, mode: .gitRemote,
                            git: .init(remoteURL: "git@h:me/a.git", commit: "abc123", branch: "main"),
                            archivePath: nil),
            ManifestProject(name: "b", originalPath: "/x/b", emoji: nil, mode: .archive,
                            git: nil, archivePath: "projects/b"),
        ]
        let sh = ProjectExportService.restoreScript(for: entries)
        XCTAssertTrue(sh.hasPrefix("#!/bin/bash"))
        XCTAssertTrue(sh.contains("git clone 'git@h:me/a.git'"))
        XCTAssertTrue(sh.contains("checkout 'abc123'"))
        XCTAssertTrue(sh.contains("cp -R projects/'b'"))
    }

    // MARK: - Helpers

    private func git(_ repo: String, _ args: [String]) { _ = Shell.run("/usr/bin/git", ["-C", repo] + args) }

    /// A throwaway git repo with one commit, optional `origin` remote, and extra files.
    private func makeGitRepo(_ name: String, remote: String?, extras: [(String, String)] = []) throws -> String {
        let path = tmp + "/" + name
        let fm = FileManager.default
        try fm.createDirectory(atPath: path, withIntermediateDirectories: true)
        git(path, ["init", "-q"])
        git(path, ["config", "user.email", "t@t.dev"])
        git(path, ["config", "user.name", "t"])
        git(path, ["config", "commit.gpgsign", "false"])
        try "hi".write(toFile: path + "/README", atomically: true, encoding: .utf8)
        for (rel, content) in extras {
            let full = path + "/" + rel
            try fm.createDirectory(atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try content.write(toFile: full, atomically: true, encoding: .utf8)
        }
        git(path, ["add", "-A"])
        git(path, ["commit", "-q", "-m", "init"])
        if let remote { git(path, ["remote", "add", "origin", remote]) }
        return path
    }

    private func tarList(_ archive: URL) -> [String] {
        Shell.run("/usr/bin/tar", ["tzf", archive.path]).lines.filter { !$0.isEmpty }
    }

    private func readManifest(_ archive: URL) throws -> Manifest {
        let r = Shell.run("/usr/bin/tar", ["xzOf", archive.path, "bundle/manifest.json"])
        return try JSONDecoder().decode(Manifest.self, from: Data(r.stdout.utf8))
    }
}

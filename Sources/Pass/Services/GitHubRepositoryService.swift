import Foundation

struct GitHubAccount: Equatable, Sendable {
    let login: String
    let name: String?
}

struct GitHubRemoteRepository: Identifiable, Equatable, Sendable {
    let id: Int64
    let owner: String
    let name: String
    let fullName: String
    let description: String?
    let cloneURL: String
    let isPrivate: Bool
    let isArchived: Bool
    let isFork: Bool
    let pushedAt: String?
    let permission: String

    var projectRepository: ProjectCreationService.GitHubRepository {
        ProjectCreationService.GitHubRepository(owner: owner, name: name, cloneURL: cloneURL)
    }
}

/// Reads the user's existing GitHub CLI authentication without handling or persisting tokens in
/// Pass. `gh api` delegates secure credential storage and SSO handling to GitHub CLI, while the
/// app only receives the account name and repository metadata needed by the new-session palette.
enum GitHubRepositoryService {
    struct Snapshot: Equatable, Sendable {
        let account: GitHubAccount
        let repositories: [GitHubRemoteRepository]
    }

    enum Failure: LocalizedError, Equatable {
        case cliUnavailable
        case signedOut
        case api(String)
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .cliUnavailable:
                return "Install GitHub CLI to connect an account."
            case .signedOut:
                return "Connect your GitHub account to search repositories."
            case .api(let detail):
                return "GitHub could not load repositories: \(detail)"
            case .invalidResponse:
                return "GitHub returned repository data Pass could not read."
            }
        }
    }

    typealias Runner = (_ executable: String, _ arguments: [String]) -> ProcResult

    static func load(
        executable: String? = resolveExecutable(),
        run: Runner = defaultRun
    ) throws -> Snapshot {
        guard let executable else { throw Failure.cliUnavailable }
        return Snapshot(
            account: try account(executable: executable, run: run),
            repositories: try repositories(executable: executable, run: run)
        )
    }

    static func account(
        executable: String? = resolveExecutable(),
        run: Runner = defaultRun
    ) throws -> GitHubAccount {
        guard let executable else { throw Failure.cliUnavailable }
        let result = run(executable, ["api", "user"])
        guard result.ok else { throw failure(for: result) }
        guard let response = try? JSONDecoder().decode(AccountResponse.self, from: Data(result.stdout.utf8)),
              !response.login.isEmpty else {
            throw Failure.invalidResponse
        }
        return GitHubAccount(login: response.login, name: response.name)
    }

    static func repositories(
        executable: String? = resolveExecutable(),
        run: Runner = defaultRun
    ) throws -> [GitHubRemoteRepository] {
        guard let executable else { throw Failure.cliUnavailable }
        let protocolResult = run(executable, ["config", "get", "git_protocol", "-h", "github.com"])
        let prefersSSH = protocolResult.ok
            && protocolResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "ssh"

        let result = run(executable, [
            "api", "--paginate", "--slurp", "-X", "GET", "user/repos",
            "-f", "per_page=100",
            "-f", "affiliation=owner,collaborator,organization_member",
            "-f", "sort=pushed",
            "-f", "direction=desc",
        ])
        guard result.ok else { throw failure(for: result) }
        guard let pages = try? JSONDecoder().decode([[RepositoryResponse]].self, from: Data(result.stdout.utf8)) else {
            throw Failure.invalidResponse
        }

        return pages.flatMap { $0 }.map { repository in
            let owner = repository.owner.login
            return GitHubRemoteRepository(
                id: repository.id,
                owner: owner,
                name: repository.name,
                fullName: repository.fullName,
                description: repository.description?.trimmingCharacters(in: .whitespacesAndNewlines)
                    .nilIfEmpty,
                cloneURL: prefersSSH ? repository.sshURL : repository.cloneURL,
                isPrivate: repository.isPrivate,
                isArchived: repository.isArchived,
                isFork: repository.isFork,
                pushedAt: repository.pushedAt,
                permission: repository.permissions.label
            )
        }
    }

    static func authenticationCommand() -> String? {
        guard let executable = resolveExecutable() else { return nil }
        return "\(Shell.singleQuoted(executable)) auth login --hostname github.com --git-protocol https --web"
    }

    static func resolveExecutable() -> String? {
        Shell.resolveViaLoginShell("gh")
    }

    private static func defaultRun(_ executable: String, _ arguments: [String]) -> ProcResult {
        Shell.run(executable, arguments, extraEnv: ["GH_PROMPT_DISABLED": "1"])
    }

    private static func failure(for result: ProcResult) -> Failure {
        let detail = [result.stderr, result.stdout]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? "gh exited with \(result.code)"
        let lowercased = detail.lowercased()
        if result.code == 4
            || lowercased.contains("authenticate")
            || lowercased.contains("authentication")
            || lowercased.contains("not logged")
            || lowercased.contains("bad credentials")
            || lowercased.contains("http 401")
            || lowercased.contains("gh auth login") {
            return .signedOut
        }
        return .api(detail)
    }

    private struct AccountResponse: Decodable {
        let login: String
        let name: String?
    }

    private struct RepositoryResponse: Decodable {
        let id: Int64
        let owner: OwnerResponse
        let name: String
        let fullName: String
        let description: String?
        let cloneURL: String
        let sshURL: String
        let isPrivate: Bool
        let isArchived: Bool
        let isFork: Bool
        let pushedAt: String?
        let permissions: PermissionResponse

        enum CodingKeys: String, CodingKey {
            case id, owner, name, description, permissions
            case fullName = "full_name"
            case cloneURL = "clone_url"
            case sshURL = "ssh_url"
            case isPrivate = "private"
            case isArchived = "archived"
            case isFork = "fork"
            case pushedAt = "pushed_at"
        }
    }

    private struct OwnerResponse: Decodable {
        let login: String
    }

    private struct PermissionResponse: Decodable {
        let admin: Bool
        let maintain: Bool?
        let push: Bool
        let triage: Bool?
        let pull: Bool

        var label: String {
            if admin { return "admin" }
            if maintain == true { return "maintain" }
            if push { return "write" }
            if triage == true { return "triage" }
            return pull ? "read" : "access"
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

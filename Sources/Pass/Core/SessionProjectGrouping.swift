import Foundation

/// Keeps each project's sessions together without changing the order within a project.
/// The first session in the current home order determines the project's position.
struct SessionProjectGroup: Identifiable {
    let id: String
    let name: String
    let emoji: String?
    var sessions: [Session]

    var waitingCount: Int { sessions.filter(\.needsUser).count }
}

enum SessionProjectGrouping {
    static func groups(_ sessions: [Session], projects: [Project],
                       includeEmptyProjects: Bool = false) -> [SessionProjectGroup] {
        var knownProjects: [String: Project] = [:]
        for project in projects where knownProjects[project.rootPath] == nil {
            knownProjects[project.rootPath] = project
        }
        var groups: [SessionProjectGroup] = []
        var indexByRoot: [String: Int] = [:]

        for session in sessions {
            let root = session.projectRoot
            if let index = indexByRoot[root] {
                groups[index].sessions.append(session)
            } else {
                indexByRoot[root] = groups.count
                let project = knownProjects[root]
                groups.append(SessionProjectGroup(
                    id: root,
                    name: project?.name ?? URL(fileURLWithPath: root).lastPathComponent,
                    emoji: project?.emoji,
                    sessions: [session]
                ))
            }
        }
        if includeEmptyProjects {
            for project in projects where indexByRoot[project.rootPath] == nil {
                indexByRoot[project.rootPath] = groups.count
                groups.append(SessionProjectGroup(id: project.rootPath, name: project.name,
                                                  emoji: project.emoji, sessions: []))
            }
        }
        return groups
    }
}

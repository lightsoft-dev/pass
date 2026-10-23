import Foundation
import Observation

/// Checks only workers that Pa has just assigned work. A quiet pane is a reason to inspect,
/// not evidence that the coding agent has stopped.
struct ProjectWorkerProgressSample {
    enum Event: Equatable {
        case quiet
        case resumed
        case disappeared
    }

    static let pollInterval: Duration = .seconds(5)
    static let quietInterval: TimeInterval = 30

    private(set) var lastProgressAt: Date
    private var previousPane: String?
    private var previousActivity: Date?
    private var missingChecks = 0
    private var reportedQuiet = false

    init(startedAt: Date) {
        lastProgressAt = startedAt
    }

    mutating func observe(now: Date, isLive: Bool, pane: String,
                          lastActivity: Date?) -> Event? {
        guard isLive else {
            missingChecks += 1
            return missingChecks >= 2 ? .disappeared : nil
        }
        missingChecks = 0

        let paneChanged = previousPane.map { $0 != pane } ?? !pane.isEmpty
        let activityChanged = lastActivity.map { activity in
            previousActivity.map { previous in activity > previous }
                ?? (activity > lastProgressAt)
        } ?? false
        previousPane = pane
        previousActivity = lastActivity
        if paneChanged || activityChanged {
            lastProgressAt = now
            if reportedQuiet {
                reportedQuiet = false
                return .resumed
            }
            return nil
        }
        if !reportedQuiet && now.timeIntervalSince(lastProgressAt) >= Self.quietInterval {
            reportedQuiet = true
            return .quiet
        }
        return nil
    }
}

@MainActor
@Observable
final class ProjectWorkerProgressMonitor {
    enum Status: Equatable { case checking, quiet }

    private struct Watch {
        let id: UUID
        let task: Task<Void, Never>
    }

    private(set) var statuses: [String: Status] = [:]
    @ObservationIgnored private var watches: [String: Watch] = [:]
    @ObservationIgnored private let sessions: SessionStore
    @ObservationIgnored private let tmux: TmuxClient
    @ObservationIgnored private let onEvent: (String, String, ProjectWorkerProgressSample.Event) -> Void

    init(sessions: SessionStore, tmux: TmuxClient = .shared,
         onEvent: @escaping (String, String, ProjectWorkerProgressSample.Event) -> Void) {
        self.sessions = sessions
        self.tmux = tmux
        self.onEvent = onEvent
    }

    func track(_ name: String, projectRoot: String) {
        stop(name)
        let id = UUID()
        statuses[name] = .checking
        let task = Task { [weak self] in
            var sample = ProjectWorkerProgressSample(startedAt: Date())
            while !Task.isCancelled {
                do { try await Task.sleep(for: ProjectWorkerProgressSample.pollInterval) }
                catch { return }
                guard let self, self.watches[name]?.id == id else { return }
                let isLive = await self.tmux.hasSession(name)
                let pane = isLive ? await self.tmux.capturePane(name, colors: false) : ""
                guard !Task.isCancelled, self.watches[name]?.id == id else { return }
                let session = self.sessions.session(named: name)
                if let session, case .pending = session.attention {
                    self.stop(name) // existing turn-end/input hooks already report to Pa
                    return
                }
                guard let event = sample.observe(now: Date(), isLive: isLive,
                                                 pane: pane, lastActivity: session?.lastActivity)
                else { continue }
                if event == .disappeared {
                    self.stop(name)
                } else {
                    self.statuses[name] = event == .quiet ? .quiet : .checking
                }
                self.onEvent(name, projectRoot, event)
                if event == .disappeared { return }
            }
        }
        watches[name] = Watch(id: id, task: task)
    }

    func stop(_ name: String) {
        watches.removeValue(forKey: name)?.task.cancel()
        statuses.removeValue(forKey: name)
    }

    func stopAll() {
        for watch in watches.values { watch.task.cancel() }
        watches.removeAll()
        statuses.removeAll()
    }
}

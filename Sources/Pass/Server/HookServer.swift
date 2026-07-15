import Foundation
import FlyingFox
import FlyingSocks

/// One received hook, ready for the main actor to route.
struct HookHit: Sendable {
    let path: String
    let raw: RawHookEvent
}

/// Handlers backing the share-extension endpoints (wired by AppDelegate to ShareAPI).
struct ShareHandlers: Sendable {
    var targets: @Sendable () async -> Data
    var send: @Sendable (Data) async -> Data
}

/// Loopback HTTP server that receives agent hook POSTs. Binds 127.0.0.1 only (no firewall
/// prompt, no LAN exposure). Publishes hits on `events`; the main actor consumes and routes.
/// Also serves the OS share extension (`/share/*`) — same port, same loopback-only rule.
actor HookServer {
    let events: AsyncStream<HookHit>
    private let continuation: AsyncStream<HookHit>.Continuation
    private var runTask: Task<Void, Never>?
    private(set) var didBind = false

    init() {
        (events, continuation) = AsyncStream.makeStream(of: HookHit.self)
    }

    func start(port: UInt16, share: ShareHandlers? = nil) async {
        guard let address = try? sockaddr_in.inet(ip4: "127.0.0.1", port: port) else {
            Log.hooks.error("could not build loopback address"); return
        }
        let server = HTTPServer(config: .init(address: address, logger: .disabled))
        let cont = continuation

        await server.appendRoute("GET /health") { _ in
            HTTPResponse(statusCode: .ok, body: Data("ok".utf8))
        }
        await server.appendRoute("POST /hook/*") { request in
            let path = request.path
            let header = request.headers[HTTPHeader("X-Pass-Session")]
            let data = (try? await request.bodyData) ?? Data()
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                cont.yield(HookHit(path: path, raw: RawHookEvent(json: json, header: header)))
            }
            return HTTPResponse(statusCode: .ok) // always 200, empty — never make the agent wait
        }
        if let share {
            let json = [HTTPHeader("Content-Type"): "application/json"]
            await server.appendRoute("GET /share/targets") { _ in
                HTTPResponse(statusCode: .ok, headers: json, body: await share.targets())
            }
            await server.appendRoute("POST /share/send") { request in
                let body = (try? await request.bodyData) ?? Data()
                return HTTPResponse(statusCode: .ok, headers: json, body: await share.send(body))
            }
        }

        runTask = Task {
            do { try await server.run() }
            catch { Log.hooks.error("hook server stopped: \(error.localizedDescription, privacy: .public)") }
        }
        try? await Task.sleep(for: .milliseconds(200))
        didBind = await healthOK(port: port)
        Log.hooks.info("hook server on 127.0.0.1:\(port) bound=\(self.didBind)")
    }

    func stop() {
        runTask?.cancel()
        continuation.finish()
    }

    private func healthOK(port: UInt16) async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/health") else { return false }
        var req = URLRequest(url: url); req.timeoutInterval = 1
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return false }
        return String(decoding: data, as: UTF8.self) == "ok"
    }
}

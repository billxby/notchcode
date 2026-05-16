// Tiny HTTP server that receives Claude Code hook callbacks.
//
// Wire format: Claude Code's `hooks` config registers shell commands. We
// register a curl that POSTs the event JSON (read from stdin) to:
//
//     http://127.0.0.1:9876/hook/<EventName>
//
// We listen on port 9876 (loopback only — ignored by external network) and
// for each connection: read the HTTP request, extract the event Kind from
// the URL path, decode the JSON body, hand it to SessionStateEngine.
//
// Why hand-roll HTTP instead of pulling in a server library:
//   - zero SPM dependencies (per project rule in notchcode-plan.md)
//   - the protocol surface we need is microscopic: one verb (POST), one
//     route prefix (/hook/), small JSON bodies (< 8KB)
//   - Network.framework's NWListener gives us the TCP plumbing for free
//
// Flutter analogy: imagine writing a `dart:io` HttpServer manually because
// the project mandates no `package:shelf`. Same shape, different keywords.

import Foundation
import Network

@MainActor
final class HookServer {
    static let shared = HookServer()
    private init() {}

    private var listener: NWListener?
    private weak var engine: SessionStateEngine?
    private var port: UInt16 = 9876

    // MARK: - Lifecycle

    func start(engine: SessionStateEngine, port: UInt16 = 9876) {
        guard listener == nil else { return }   // idempotent
        self.engine = engine
        self.port = port

        do {
            // NWParameters.tcp = standard TCP listener parameters.
            let params = NWParameters.tcp
            // Allow rapid restarts during dev (avoids "Address already in use"
            // for ~60s after a crash).
            params.allowLocalEndpointReuse = true

            let nwPort = NWEndpoint.Port(integerLiteral: port)
            listener = try NWListener(using: params, on: nwPort)
        } catch {
            print("[Notchcode] HookServer failed to bind on \(port): \(error)")
            return
        }

        // Filter: reject any connection whose remote endpoint isn't loopback.
        // Belt-and-suspenders even though we'll likely also see a firewall
        // prompt on first launch.
        listener?.newConnectionHandler = { conn in
            // newConnectionHandler is a @Sendable nonisolated closure invoked
            // on Network.framework's queue. Hop to MainActor before touching
            // any of our actor-isolated state.
            if Self.isLoopback(conn.endpoint) {
                Task { @MainActor in
                    HookServer.shared.handle(connection: conn)
                }
            } else {
                conn.cancel()
            }
        }

        let boundPort = self.port
        listener?.stateUpdateHandler = { state in
            switch state {
            case .ready:
                print("[Notchcode] HookServer listening on 127.0.0.1:\(boundPort)")
            case .failed(let err):
                print("[Notchcode] HookServer failed: \(err)")
                // Tear down so a future start() isn't blocked by the idempotency
                // guard. The most common cause is another process holding the
                // port (usually a stale instance of this app).
                Task { @MainActor in HookServer.shared.stop() }
            case .cancelled:
                print("[Notchcode] HookServer cancelled")
            default:
                break
            }
        }

        listener?.start(queue: .main)
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Connection handling

    private func handle(connection: NWConnection) {
        connection.start(queue: .main)
        readRequest(on: connection)
    }

    /// Recursively read until we have headers + a complete body. For the
    /// payloads we receive (small JSON), this almost always returns in one
    /// shot, but we still handle the multi-chunk case correctly.
    private func readRequest(
        on conn: NWConnection,
        accumulated: Data = Data(),
        contentLength: Int? = nil
    ) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, _ in
            // receive's completion is @Sendable nonisolated. Hop back to
            // MainActor so we can touch self's state.
            Task { @MainActor in
                let `self` = HookServer.shared

                var buffer = accumulated
                if let data { buffer.append(data) }

                // Have we seen the header/body separator yet?
                let separator = Data("\r\n\r\n".utf8)
                guard let sepRange = buffer.range(of: separator) else {
                    if isComplete {
                        self.respond(conn: conn, status: "400 Bad Request"); return
                    }
                    self.readRequest(on: conn, accumulated: buffer, contentLength: contentLength)
                    return
                }

                let headerData = buffer.subdata(in: 0..<sepRange.lowerBound)
                let bodyStart = sepRange.upperBound
                let bodySoFar = buffer.subdata(in: bodyStart..<buffer.count)

                // Determine expected body length — parse Content-Length once.
                let expectedLength = contentLength ?? Self.parseContentLength(headerData) ?? bodySoFar.count

                if bodySoFar.count >= expectedLength {
                    let body = bodySoFar.prefix(expectedLength)
                    self.processRequest(headers: headerData, body: Data(body), conn: conn)
                    return
                }

                if isComplete {
                    // Connection closed before promised body arrived; use what we have.
                    self.processRequest(headers: headerData, body: bodySoFar, conn: conn)
                    return
                }

                self.readRequest(on: conn, accumulated: buffer, contentLength: expectedLength)
            }
        }
    }

    private func processRequest(headers: Data, body: Data, conn: NWConnection) {
        guard
            let headerStr = String(data: headers, encoding: .utf8),
            let firstLine = headerStr.split(separator: "\r\n", omittingEmptySubsequences: true).first
        else {
            respond(conn: conn, status: "400 Bad Request"); return
        }

        // Request line: "POST /hook/PreToolUse HTTP/1.1"
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "POST" else {
            respond(conn: conn, status: "405 Method Not Allowed"); return
        }
        let path = String(parts[1])

        let prefix = "/hook/"
        guard path.hasPrefix(prefix) else {
            respond(conn: conn, status: "404 Not Found"); return
        }
        let kindStr = String(path.dropFirst(prefix.count))
        guard let kind = HookEvent.Kind(rawValue: kindStr) else {
            respond(conn: conn, status: "400 Unknown Hook Kind"); return
        }

        let pid = Self.parseClaudePID(headers)
        let event = HookEvent.decode(kind: kind, body: body, claudePid: pid)
        engine?.handleHookEvent(event)
        respond(conn: conn, status: "200 OK")
    }

    private func respond(conn: NWConnection, status: String) {
        // Connection: close tells curl not to wait for a keep-alive timeout.
        let response = "HTTP/1.1 \(status)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        conn.send(content: response.data(using: .utf8)!, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }

    // MARK: - Helpers

    nonisolated private static func parseContentLength(_ headerData: Data) -> Int? {
        guard let str = String(data: headerData, encoding: .utf8) else { return nil }
        for line in str.split(separator: "\r\n") {
            let lower = line.lowercased()
            if lower.hasPrefix("content-length:") {
                let value = lower.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
                return Int(value)
            }
        }
        return nil
    }

    /// v0.95 — extract `X-Claude-PID: <pid>` set by install-hooks.sh. Lets
    /// the engine track a specific Claude Code process per session so the
    /// notch can SIGTERM exactly one session without affecting siblings.
    nonisolated private static func parseClaudePID(_ headerData: Data) -> Int32? {
        guard let str = String(data: headerData, encoding: .utf8) else { return nil }
        for line in str.split(separator: "\r\n") {
            let lower = line.lowercased()
            if lower.hasPrefix("x-claude-pid:") {
                let value = lower.dropFirst("x-claude-pid:".count).trimmingCharacters(in: .whitespaces)
                return Int32(value)
            }
        }
        return nil
    }

    /// True if a remote endpoint is on 127.x.x.x (IPv4) or ::1 (IPv6).
    nonisolated private static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let addr):
            // raw bytes are network byte order; first byte == 127 covers all loopback.
            return addr.rawValue.first == 127
        case .ipv6(let addr):
            let bytes = [UInt8](addr.rawValue)
            // ::1  →  fifteen zero bytes followed by 0x01
            let loopback: [UInt8] = [0,0,0,0, 0,0,0,0, 0,0,0,0, 0,0,0,1]
            return bytes == loopback
        case .name:
            return false
        @unknown default:
            return false
        }
    }
}

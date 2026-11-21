import Foundation
import Network

/// A short-lived IPv4 loopback listener. It never binds a public interface.
@MainActor final class ChatGPTLoopback {
    private var listener: NWListener?
    private var ready: CheckedContinuation<URL, Error>?
    private var result: CheckedContinuation<URL, Error>?
    private var completed: Result<URL, Error>?
    private var timer: Task<Void, Never>?
    private var connections: [NWConnection] = []
    private var redirect: URL?
    var expectedState: String?

    func start() async throws -> URL {
        try Task.checkCancellation()
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    guard let port = self.listener?.port else { return }
                    let url = URL(string: "http://127.0.0.1:\(port.rawValue)/auth/callback")!
                    self.redirect = url
                    self.ready?.resume(returning: url); self.ready = nil
                case .failed: self.finish(.failure(WorkspaceError("Could not open the local sign-in callback. Try again.")))
                default: break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                guard let self, self.completed == nil, self.connections.count < 8 else { connection.cancel(); return }
                self.connections.append(connection)
                connection.start(queue: .main)
                self.receive(connection, data: Data())
            }
        }
        timer = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(180)) } catch { return }
            self?.finish(.failure(WorkspaceError("Sign-in timed out. Choose Continue with ChatGPT to try again.")))
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                ready = continuation
                listener.start(queue: .main)
            }
        } onCancel: { Task { @MainActor in self.cancel() } }
    }

    func wait() async throws -> URL {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            if let completed { return try completed.get() }
            return try await withCheckedThrowingContinuation { result = $0 }
        } onCancel: { Task { @MainActor in self.cancel() } }
    }

    func cancel() { finish(.failure(CancellationError())) }

    private func receive(_ connection: NWConnection, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] chunk, _, ended, error in
            Task { @MainActor in
                guard let self, self.completed == nil else { connection.cancel(); return }
                let buffer = data + (chunk ?? Data())
                guard buffer.count <= 16_384, error == nil else { self.close(connection); return }
                guard let request = String(data: buffer, encoding: .utf8), request.contains("\r\n\r\n") else {
                    if ended { self.close(connection) } else { self.receive(connection, data: buffer) }
                    return
                }
                let line = request.components(separatedBy: "\r\n").first?.split(separator: " ") ?? []
                guard line.count == 3, line[0] == "GET", line[1].hasPrefix("/auth/callback?"),
                      let redirect = self.redirect,
                      let url = URL(string: String(line[1]), relativeTo: redirect)?.absoluteURL,
                      url.host == "127.0.0.1", url.port == redirect.port,
                      let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
                      query.filter({ $0.name == "state" }).count == 1,
                      query.first(where: { $0.name == "state" })?.value == self.expectedState else {
                    self.respond(connection, text: "This sign-in callback is not valid. Return to Voxstead.", status: "400 Bad Request")
                    return
                }
                self.respond(connection, text: "Return to Voxstead to finish connecting your account.", status: "200 OK")
                // Let the HTTP response finish before closing this connection.
                self.connections.removeAll { $0 === connection }
                self.finish(.success(url))
            }
        }
    }

    private func respond(_ connection: NWConnection, text: String, status: String) {
        let content = "HTTP/1.1 \(status)\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\nContent-Security-Policy: default-src 'none'\r\nConnection: close\r\nContent-Length: \(text.utf8.count)\r\n\r\n\(text)"
        connection.send(content: Data(content.utf8), completion: .contentProcessed { [weak self] _ in
            connection.cancel()
            Task { @MainActor in self?.connections.removeAll { $0 === connection } }
        })
    }
    private func close(_ connection: NWConnection) {
        connection.cancel(); connections.removeAll { $0 === connection }
    }
    private func finish(_ outcome: Result<URL, Error>) {
        guard completed == nil else { return }
        completed = outcome
        ready?.resume(with: outcome); ready = nil
        result?.resume(with: outcome); result = nil
        timer?.cancel(); timer = nil
        listener?.cancel(); listener = nil
        connections.forEach { $0.cancel() }; connections = []
    }
}

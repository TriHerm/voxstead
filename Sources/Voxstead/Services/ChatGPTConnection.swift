import Foundation

struct ChatGPTCredentials: Codable, Sendable {
    let clientID: String
    let subject: String
    var email: String?
    var accessToken: String
    var refreshToken: String?
    var idToken: String?
    var scopes: [String]
    var expires: Date
    var planEnabled: Bool { scopes.contains("chatgpt.tokens.use.direct") && scopes.contains("resource.invoke") }
    var connected: Bool { !accessToken.isEmpty }
}

struct ChatGPTModel: Identifiable, Sendable {
    let id: String
    let name: String
}

actor ChatGPTConnection {
    static let shared = ChatGPTConnection()
    private let session: URLSession
    private var refreshes: [UUID: (UUID, Task<ChatGPTCredentials, Error>)] = [:]
    private var epochs: [UUID: UUID] = [:]
    static let usageURL = URL(string: "https://chatgpt.com/settings/usage")!

    init(session: URLSession? = nil) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 90
        self.session = session ?? URLSession(configuration: configuration, delegate: ChatGPTNoRedirects(), delegateQueue: nil)
    }

    func read(_ id: UUID) throws -> ChatGPTCredentials? {
        let raw = try Keychain.read(id)
        guard !raw.isEmpty else { return nil }
        return try JSONDecoder().decode(ChatGPTCredentials.self, from: Data(raw.utf8))
    }

    func save(_ credentials: ChatGPTCredentials, id: UUID) async throws {
        epochs[id] = UUID()
        refreshes.removeValue(forKey: id)?.1.cancel()
        let lock = try await ChatGPTCredentialLock.acquire(id)
        defer { withExtendedLifetime(lock) {} }
        try Task.checkCancellation()
        try persist(credentials, id: id)
    }

    private func persist(_ credentials: ChatGPTCredentials, id: UUID) throws {
        let encoded = try JSONEncoder().encode(credentials)
        try Keychain.write(String(decoding: encoded, as: UTF8.self), for: id)
    }

    func exchange(attempt: ChatGPTIdentity.Attempt, callback: URL, previous: ChatGPTCredentials?) async throws -> ChatGPTCredentials {
        let reply = try attempt.callback(callback)
        let object = try await tokenRequest(["grant_type": "authorization_code", "client_id": reply.client,
                                             "code": reply.code, "code_verifier": attempt.verifier,
                                             "redirect_uri": attempt.redirect.absoluteString, "resource": ChatGPTIdentity.resource])
        guard let idToken = object.id_token else { throw WorkspaceError("ChatGPT did not return a verifiable identity.") }
        let identity = try await verify(idToken, client: reply.client, nonce: attempt.nonce)
        if let previous, (identity.subject != previous.subject || reply.client != previous.clientID) {
            throw WorkspaceError("This connection belongs to another account. Add a new ChatGPT connection instead.")
        }
        try Task.checkCancellation()
        return try object.credentials(client: reply.client, identity: identity, previous: nil)
    }

    func accessToken(_ id: UUID) async throws -> String {
        guard Bundle.main.object(forInfoDictionaryKey: "VoxsteadAllowsChatGPTPlan") as? Bool != false else {
            throw WorkspaceError("ChatGPT plan usage is not enabled for this edition. Choose another provider.")
        }
        guard let credentials = try read(id), credentials.connected else { throw WorkspaceError("Sign in to ChatGPT in Settings → AI providers.") }
        guard credentials.planEnabled else { throw WorkspaceError("ChatGPT plan usage is not enabled. Enable it in this connection or choose another provider.") }
        if credentials.expires.timeIntervalSinceNow > 60 { return credentials.accessToken }
        let epoch: UUID
        let task: Task<ChatGPTCredentials, Error>
        if let existing = refreshes[id] { (epoch, task) = existing }
        else {
            epoch = UUID(); epochs[id] = epoch
            task = Task { try await self.refreshLocked(id) }
            refreshes[id] = (epoch, task)
        }
        do {
            let updated = try await task.value
            try Task.checkCancellation()
            guard epochs[id] == epoch else { throw CancellationError() }
            refreshes[id] = nil
            guard updated.planEnabled else { throw WorkspaceError("ChatGPT plan usage is no longer enabled. Reconnect from Settings.") }
            return updated.accessToken
        } catch {
            if epochs[id] == epoch {
                refreshes[id] = nil
            }
            throw error
        }
    }

    // Sign-out keeps the verified registration for later reauthorization.
    func disconnect(_ id: UUID) async throws -> Bool {
        epochs[id] = UUID()
        refreshes.removeValue(forKey: id)?.1.cancel()
        let lock = try await ChatGPTCredentialLock.acquire(id)
        defer { withExtendedLifetime(lock) {} }
        guard var record = try read(id) else { return true }
        let refresh = record.refreshToken
        record.accessToken = ""; record.refreshToken = nil; record.idToken = nil
        try persist(record, id: id)
        guard let refresh else { return true }
        do {
            let discovery = try await jsonGET(URL(string: ChatGPTIdentity.issuer + "/.well-known/openid-configuration")!)
            guard let address = discovery["revocation_endpoint"] as? String, let endpoint = URL(string: address),
                  endpoint.scheme == "https", endpoint.host == "auth.openai.com", endpoint.user == nil, endpoint.password == nil else { return false }
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = ChatGPTIdentity.form(["client_id": record.clientID, "token": refresh, "token_type_hint": "refresh_token"])
            let (_, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch { return false }
    }

    func models(_ id: UUID) async throws -> [ChatGPTModel] {
        let token = try await accessToken(id)
        let object = try await jsonGET(URL(string: ChatGPTIdentity.resource + "/models")!, token: token)
        guard let entries = object["models"] as? [[String: Any]] else {
            throw WorkspaceError("ChatGPT returned an unsupported model catalog. Try again later.")
        }
        var seen = Set<String>()
        return entries.compactMap { item in
            guard item["visibility"] as? String == "list", let id = item["slug"] as? String, !id.isEmpty,
                  seen.insert(id).inserted else { return nil }
            return ChatGPTModel(id: id, name: item["display_name"] as? String ?? id)
        }
    }

    private func refreshLocked(_ id: UUID) async throws -> ChatGPTCredentials {
        let lock = try await ChatGPTCredentialLock.acquire(id)
        defer { withExtendedLifetime(lock) {} }
        guard var current = try read(id), current.connected else {
            throw WorkspaceError("This ChatGPT connection is signed out. Reconnect in Settings.")
        }
        if current.expires.timeIntervalSinceNow > 60 { return current }
        do {
            let updated = try await refresh(current)
            try Task.checkCancellation()
            try persist(updated, id: id)
            return updated
        } catch {
            if let failure = error as? TokenFailure, failure.terminal {
                current.accessToken = ""; current.refreshToken = nil; current.idToken = nil
                try persist(current, id: id)
            }
            throw error
        }
    }

    private func refresh(_ old: ChatGPTCredentials) async throws -> ChatGPTCredentials {
        guard let refresh = old.refreshToken else { throw TokenFailure(code: "invalid_refresh_token") }
        let response = try await tokenRequest(["grant_type": "refresh_token", "client_id": old.clientID,
                                               "refresh_token": refresh, "resource": ChatGPTIdentity.resource])
        var identity = ChatGPTIdentity.Identity(subject: old.subject, email: old.email)
        if let idToken = response.id_token {
            identity = try await verify(idToken, client: old.clientID, nonce: nil)
            guard identity.subject == old.subject else { throw WorkspaceError("ChatGPT returned a different account during renewal. Sign in again.") }
        }
        try Task.checkCancellation()
        return try response.credentials(client: old.clientID, identity: identity, previous: old)
    }

    private func verify(_ token: String, client: String, nonce: String?) async throws -> ChatGPTIdentity.Identity {
        let (data, response) = try await session.data(from: URL(string: ChatGPTIdentity.issuer + "/.well-known/jwks.json")!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw WorkspaceError("Could not verify ChatGPT identity. Try again later.") }
        return try ChatGPTIdentity.validate(token, jwks: data, client: client, nonce: nonce)
    }

    private func jsonGET(_ url: URL, token: String? = nil) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw WorkspaceError("Could not load the ChatGPT connection (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)). Check your account and try again.")
        }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    private func tokenRequest(_ fields: [String: String]) async throws -> Tokens {
        var request = URLRequest(url: URL(string: ChatGPTIdentity.issuer + "/api/accounts/oauth/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = ChatGPTIdentity.form(fields)
        let (data, response) = try await session.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw WorkspaceError("No response from ChatGPT sign-in.") }
        guard (200..<300).contains(status) else {
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            // Never display raw authorization responses, which can contain credentials.
            throw TokenFailure(code: object?["error"] as? String ?? "http_\(status)")
        }
        return try JSONDecoder().decode(Tokens.self, from: data)
    }

    struct TokenFailure: LocalizedError {
        let code: String
        var terminal: Bool { ["invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired", "refresh_token_invalidated", "refresh_token_reused"].contains(code) }
        var errorDescription: String? {
            terminal ? "ChatGPT authorization expired or was revoked. Please sign in again." : "ChatGPT could not complete authorization. Try again later."
        }
    }
    struct Tokens: Decodable {
        let access_token: String
        let refresh_token: String?
        let id_token: String?
        let token_type: String
        let expires_in: Double
        let scope: String?
        func credentials(client: String, identity: ChatGPTIdentity.Identity, previous: ChatGPTCredentials?) throws -> ChatGPTCredentials {
            guard token_type.lowercased() == "bearer", !access_token.isEmpty, expires_in.isFinite, expires_in > 0 else {
                throw WorkspaceError("ChatGPT returned incomplete credentials. Please reconnect.")
            }
            return ChatGPTCredentials(clientID: client, subject: identity.subject, email: identity.email,
                accessToken: access_token, refreshToken: refresh_token ?? previous?.refreshToken,
                idToken: id_token ?? previous?.idToken,
                scopes: scope.map { $0.split(separator: " ").map(String.init) } ?? previous?.scopes ?? [],
                expires: .now.addingTimeInterval(expires_in))
        }
    }
}

final class ChatGPTNoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

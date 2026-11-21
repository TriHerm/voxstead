import Foundation
import CryptoKit
import Security
import Testing
import Synchronization
@testable import Voxstead

struct ChatGPTTests {
    @Test func authorizationUsesPKCEAndRejectsCrossAccountCallbacks() throws {
        let redirect = URL(string: "http://127.0.0.1:49152/auth/callback")!
        let attempt = try ChatGPTIdentity.Attempt(redirect: redirect, clientID: nil, host: "urn:uuid:test")
        let items = try #require(URLComponents(url: attempt.authorizationURL(), resolvingAgainstBaseURL: false)?.queryItems)
        let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        #expect(query["client_id"] == "dynamic_agent_client")
        #expect(query["agent_name_hint"] == "Voxstead")
        #expect(query["code_challenge"] == ChatGPTIdentity.encode(Data(SHA256.hash(data: Data(attempt.verifier.utf8)))))
        #expect(query["scope"]?.contains("chatgpt.tokens.use.direct") == true)
        #expect(attempt.state != attempt.nonce)
        let callback = URL(string: redirect.absoluteString + "?state=\(attempt.state)&code=test-code&client_id=oaiapp_test")!
        #expect(try attempt.callback(callback).client == "oaiapp_test")
        for query in ["state=wrong&code=c&client_id=oaiapp_test", "state=\(attempt.state)&code=c", "state=\(attempt.state)&code=c&client_id=dynamic_agent_client", "state=\(attempt.state)&state=wrong&code=c&client_id=oaiapp_test", "state=\(attempt.state)&error=access_denied"] {
            #expect(throws: (any Error).self) { try attempt.callback(URL(string: redirect.absoluteString + "?" + query)!) }
        }
        let returning = try ChatGPTIdentity.Attempt(redirect: redirect, clientID: "oaiapp_saved", host: "urn:uuid:test")
        let returned = URL(string: redirect.absoluteString + "?state=\(returning.state)&code=c&client_id=oaiapp_other")!
        #expect(throws: (any Error).self) { try returning.callback(returned) }
        #expect(!returning.authorizationURL().absoluteString.contains("agent_name_hint"))
    }

    @Test func identityRequiresSignatureIssuerAudienceExpiryAndNonce() throws {
        let attrs: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: 2048]
        let key = try #require(SecKeyCreateRandomKey(attrs as CFDictionary, nil))
        let publicKey = try #require(SecKeyCopyPublicKey(key))
        let data = try #require(SecKeyCopyExternalRepresentation(publicKey, nil)) as Data
        var offset = 0
        func readTLV(_ data: Data, _ offset: inout Int) -> Data {
            offset += 1
            var size = Int(data[offset]); offset += 1
            if size >= 128 {
                let count = size & 127; size = 0
                for _ in 0..<count { size = size * 256 + Int(data[offset]); offset += 1 }
            }
            let value = data.subdata(in: offset..<offset + size); offset += size
            return value
        }
        let sequence = readTLV(data, &offset); offset = 0
        let n = readTLV(sequence, &offset), e = readTLV(sequence, &offset)
        let jwks = try JSONSerialization.data(withJSONObject: ["keys": [["kid": "test", "kty": "RSA", "alg": "RS256", "n": ChatGPTIdentity.encode(n), "e": ChatGPTIdentity.encode(e)]]])
        let now = Date.now.timeIntervalSince1970
        let claims: [String: Any] = ["iss": ChatGPTIdentity.issuer, "aud": "oaiapp_test", "sub": "test-account", "email": "fixture@example.invalid", "exp": now + 300, "iat": now, "nonce": "nonce"]
        func token(_ claims: [String: Any], alg: String = "RS256") throws -> String {
            let header = try JSONSerialization.data(withJSONObject: ["alg": alg, "kid": "test"])
            let payload = try JSONSerialization.data(withJSONObject: claims)
            let message = ChatGPTIdentity.encode(header) + "." + ChatGPTIdentity.encode(payload)
            let signature = try #require(SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, Data(message.utf8) as CFData, nil)) as Data
            return message + "." + ChatGPTIdentity.encode(signature)
        }
        #expect(try ChatGPTIdentity.validate(token(claims), jwks: jwks, client: "oaiapp_test", nonce: "nonce").subject == "test-account")
        for (field, value): (String, Any) in [("iss", "https://example.invalid"), ("aud", "other"), ("exp", now - 1), ("nonce", "wrong"), ("iat", now + 90), ("sub", "")] {
            var invalid = claims; invalid[field] = value
            #expect(throws: (any Error).self) { try ChatGPTIdentity.validate(token(invalid), jwks: jwks, client: "oaiapp_test", nonce: "nonce") }
        }
        #expect(throws: (any Error).self) { try ChatGPTIdentity.validate(token(claims, alg: "none"), jwks: jwks, client: "oaiapp_test", nonce: "nonce") }
        let valid = try token(claims)
        let pieces = valid.split(separator: ".")
        let tampered = pieces[0] + "." + ChatGPTIdentity.encode(Data("{}".utf8)) + "." + pieces[2]
        #expect(throws: (any Error).self) { try ChatGPTIdentity.validate(tampered, jwks: jwks, client: "oaiapp_test", nonce: "nonce") }
    }

    @Test @MainActor func loopbackRejectsWrongStateThenCompletesAndCancels() async throws {
        let listener = ChatGPTLoopback()
        defer { listener.cancel() }
        let redirect = try await listener.start()
        listener.expectedState = "correct"
        #expect(redirect.host == "127.0.0.1")
        let (_, invalid) = try await URLSession.shared.data(from: URL(string: redirect.absoluteString + "?state=wrong&code=x")!)
        #expect((invalid as? HTTPURLResponse)?.statusCode == 400)
        let callback = URL(string: redirect.absoluteString + "?state=correct&code=x&client_id=oaiapp_test")!
        let (_, response) = try await URLSession.shared.data(from: callback)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(try await listener.wait() == callback)
        let canceled = ChatGPTLoopback()
        _ = try await canceled.start()
        canceled.cancel()
        do { _ = try await canceled.wait(); Issue.record("Canceled listener returned success") }
        catch { #expect(error is CancellationError) }
    }

    @Test func streamsRejectLateFailuresAndPreserveToolItems() throws {
        var parser = ChatGPTResponseStream()
        #expect(try parser.accept(line: "data: {\"type\":\"response.output_text.delta\",\"delta\":\"partial\"}") == nil)
        var preview = ""
        #expect(try parser.accept(line: "", onDelta: { preview += $0 }) == nil)
        #expect(preview == "partial")
        _ = try parser.accept(line: "data: {\"type\":\"response.failed\",\"response\":{\"error\":{\"code\":\"subscription_sharing_usage_limit_exceeded\"}}}")
        do { _ = try parser.accept(line: ""); Issue.record("Accepted a late failure") }
        catch { #expect(error.localizedDescription.contains("Manage usage")) }
        var complete = ChatGPTResponseStream()
        let json = "{\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[{\"type\":\"function_call\",\"call_id\":\"call1\",\"name\":\"echo\",\"arguments\":\"{}\"},{\"type\":\"reasoning\",\"encrypted_content\":\"opaque\"}]}}"
        _ = try complete.accept(line: "data: " + json)
        let completed = try complete.accept(line: "")
        let result = try #require(completed)
        #expect(result[0]["call_id"] as? String == "call1")
        #expect(result[1]["encrypted_content"] as? String == "opaque")
    }

    @Test func scopeOmissionDoesNotGrantPlanAndRefreshRetainsRotation() throws {
        let identity = ChatGPTIdentity.Identity(subject: "test", email: nil)
        let raw = Data(#"{"access_token":"test","token_type":"Bearer","expires_in":3600}"#.utf8)
        let token = try JSONDecoder().decode(ChatGPTConnection.Tokens.self, from: raw)
        let record = try token.credentials(client: "oaiapp_test", identity: identity, previous: nil)
        #expect(!record.planEnabled)
        var old = record; old.scopes = ["resource.invoke", "chatgpt.tokens.use.direct"]; old.refreshToken = "old"
        let renewal = try JSONDecoder().decode(ChatGPTConnection.Tokens.self, from: Data(#"{"access_token":"new","refresh_token":"rotated","token_type":"Bearer","expires_in":300}"#.utf8))
        let updated = try renewal.credentials(client: old.clientID, identity: identity, previous: old)
        #expect(updated.refreshToken == "rotated")
        #expect(updated.planEnabled)
    }
}

private final class ChatGPTFixtureProtocol: URLProtocol, @unchecked Sendable {
    static let refreshCounts = Mutex<[String: Int]>([:])
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let url = try #require(request.url)
            var data = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let read = stream.read(&buffer, maxLength: buffer.count)
                    if read <= 0 { break }
                    data.append(contentsOf: buffer.prefix(read))
                }
            }
            var result: Data
            var status = 200
            var type = "application/json"
            switch url.path {
            case "/v1/responses":
                #expect(url.host == "api.openai.com")
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-access")
                let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
                #expect(body["store"] as? Bool == false)
                #expect(body["stream"] as? Bool == true)
                #expect(body["messages"] == nil)
                let input = body["input"] as? [[String: Any]] ?? []
                let continued = input.contains { $0["type"] as? String == "function_call_output" }
                let model = body["model"] as? String
                if model == "fixture-interrupt" {
                    result = Data("data: {\"type\":\"response.output_text.delta\",\"delta\":\"unfinished\"}\n\n".utf8)
                } else if model == "fixture-limit" {
                    result = Data("data: {\"type\":\"response.failed\",\"response\":{\"error\":{\"code\":\"subscription_sharing_usage_limit_exceeded\"}}}\n\n".utf8)
                } else {
                    let output: [[String: Any]]
                    if continued {
                        #expect(input.contains { $0["encrypted_content"] as? String == "opaque" })
                        #expect(input.contains { $0["output"] as? String == "approved result" })
                        output = [["type": "message", "content": [["type": "output_text", "text": "Done"]]]]
                    } else {
                        output = [["type": "reasoning", "encrypted_content": "opaque"],
                                  ["type": "function_call", "call_id": "call-1", "name": "echo", "arguments": "{\"text\":\"hello\"}"]]
                    }
                    let event = try JSONSerialization.data(withJSONObject: ["type": "response.completed", "response": ["status": "completed", "output": output]])
                    result = Data("data: ".utf8) + event + Data("\n\n".utf8)
                }
                type = "text/event-stream"
            case "/v1/models":
                result = Data(#"{"models":[{"slug":"second","display_name":"Second model","visibility":"list"},{"slug":"hidden","visibility":"hide"},{"slug":"first","display_name":"First model","visibility":"list"}]}"#.utf8)
            case "/api/accounts/oauth/token":
                let form = String(decoding: data, as: UTF8.self)
                Self.refreshCounts.withLock { $0[form, default: 0] += 1 }
                #expect(form.contains("grant_type=refresh_token"))
                #expect(!form.contains("scope="))
                if form.contains("refresh_token=revoked") {
                    status = 400; result = Data(#"{"error":"invalid_grant"}"#.utf8)
                } else {
                    result = Data(#"{"access_token":"fixture-access","refresh_token":"rotated","token_type":"Bearer","expires_in":3600}"#.utf8)
                }
            case "/.well-known/openid-configuration":
                result = Data(#"{"revocation_endpoint":"https://auth.openai.com/api/accounts/oauth/revoke"}"#.utf8)
            case "/api/accounts/oauth/revoke":
                #expect(String(decoding: data, as: UTF8.self).contains("token_type_hint=refresh_token"))
                result = Data()
            default:
                Issue.record("Unexpected network endpoint: \(url.path)")
                status = 404; result = Data()
            }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": type])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: result)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

extension ChatGPTTests {
    private func fixtureSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChatGPTFixtureProtocol.self]
        return URLSession(configuration: configuration)
    }
    private func fixtureCredentials(client: String = "oaiapp_fixture") -> ChatGPTCredentials {
        ChatGPTCredentials(clientID: client, subject: "fixture-user", email: nil,
            accessToken: "fixture-access", refreshToken: "fixture-refresh", idToken: nil,
            scopes: ["resource.invoke", "chatgpt.tokens.use.direct"], expires: .now.addingTimeInterval(3600))
    }

    @Test func responsesUseFixedEndpointAndKeepMCPContinuation() async throws {
        let id = UUID()
        defer { try? Keychain.write("", for: id) }
        try await ChatGPTConnection.shared.save(fixtureCredentials(), id: id)
        let session = fixtureSession()
        defer { session.invalidateAndCancel() }
        let profile = ProviderProfile(id: id, kind: .chatGPT, name: "ChatGPT", endpoint: "https://untrusted.invalid", model: "fixture")
        let client = ModelClient(profile: profile, key: "ignored", session: session)
        let first = try await client.reply(system: "Test", prompt: "Test", tools: [])
        let call = try #require(first.calls.first)
        #expect(call.id == "call-1")
        let second = try await client.continueReply(system: "Test", results: [(call, "approved result")], tools: [])
        #expect(second.text == "Done")
        for model in ["fixture-interrupt", "fixture-limit"] {
            var failedProfile = profile; failedProfile.model = model
            do {
                _ = try await ModelClient(profile: failedProfile, key: "", session: session).reply(system: "test", prompt: "test", tools: [])
                Issue.record("Accepted incomplete response")
            } catch {
                #expect(error.localizedDescription.contains(model == "fixture-limit" ? "Manage usage" : "interrupted"))
            }
        }
    }

    @Test func refreshCatalogAndDisconnectKeepRegistration() async throws {
        let session = fixtureSession()
        defer { session.invalidateAndCancel() }
        let connection = ChatGPTConnection(session: session)
        let id = UUID()
        defer { try? Keychain.write("", for: id) }
        var credentials = fixtureCredentials(); credentials.expires = .distantPast
        try await connection.save(credentials, id: id)
        async let a = connection.accessToken(id)
        async let b = connection.accessToken(id)
        let tokens = try await [a, b]
        #expect(tokens == ["fixture-access", "fixture-access"])
        #expect(try await connection.read(id)?.refreshToken == "rotated")
        let catalog = try await connection.models(id)
        #expect(catalog.map(\.id) == ["second", "first"])
        #expect(catalog.first?.name == "Second model")
        #expect(try await connection.disconnect(id))
        let signedOut = try #require(await connection.read(id))
        #expect(!signedOut.connected && signedOut.refreshToken == nil)
        #expect(signedOut.clientID == "oaiapp_fixture" && signedOut.subject == "fixture-user")
        credentials.refreshToken = "revoked"
        try await connection.save(credentials, id: id)
        do { _ = try await connection.accessToken(id); Issue.record("Accepted revoked refresh token") }
        catch { #expect(error.localizedDescription.contains("sign in again")) }
        #expect(try await connection.read(id)?.connected == false)
    }
}


extension ChatGPTTests {
    @Test func separateConnectionInstancesSerializeRotatingRefresh() async throws {
        let session = fixtureSession()
        defer { session.invalidateAndCancel() }
        let first = ChatGPTConnection(session: session), second = ChatGPTConnection(session: session)
        let id = UUID()
        defer { try? Keychain.write("", for: id) }
        var credentials = fixtureCredentials(client: "oaiapp_" + id.uuidString)
        credentials.expires = .distantPast
        try await first.save(credentials, id: id)
        async let a = first.accessToken(id)
        async let b = second.accessToken(id)
        let tokens = try await [a, b]
        #expect(tokens == ["fixture-access", "fixture-access"])
        let count = ChatGPTFixtureProtocol.refreshCounts.withLock { values in
            values.filter { $0.key.contains(credentials.clientID) }.values.reduce(0, +)
        }
        #expect(count == 1)
    }
}

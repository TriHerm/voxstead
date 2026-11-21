import CryptoKit
import Foundation
import Security

// Public-client OAuth helpers. Only verified identities may enter Keychain.
enum ChatGPTIdentity {
    static let issuer = "https://auth.openai.com"
    static let resource = "https://api.openai.com/v1"
    static let scope = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"

    static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw WorkspaceError("Could not prepare a secure sign-in. Try again.")
        }
        return encode(Data(bytes))
    }

    static func encode(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ value: String) -> Data? {
        let base = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        return Data(base64Encoded: base + String(repeating: "=", count: (4 - base.count % 4) % 4))
    }

    static func form(_ fields: [String: String]) -> Data {
        let safe = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return Data(fields.sorted { $0.key < $1.key }.map {
            "\($0.key.addingPercentEncoding(withAllowedCharacters: safe)!)=\($0.value.addingPercentEncoding(withAllowedCharacters: safe)!)"
        }.joined(separator: "&").utf8)
    }

    struct Attempt: Sendable {
        let state: String
        let nonce: String
        let verifier: String
        let redirect: URL
        let clientID: String?
        let host: String

        init(redirect: URL, clientID: String?, host: String) throws {
            self.redirect = redirect; self.clientID = clientID; self.host = host
            state = try random(); nonce = try random(); verifier = try random()
        }

        func authorizationURL(reconsent: Bool = false) -> URL {
            var fields = ["client_id": clientID ?? "dynamic_agent_client", "ext_agent_host_id": host,
                          "response_type": "code", "redirect_uri": redirect.absoluteString,
                          "scope": scope, "resource": resource, "state": state, "nonce": nonce,
                          "code_challenge_method": "S256", "code_challenge": encode(Data(SHA256.hash(data: Data(verifier.utf8))))]
            if clientID == nil { fields["agent_name_hint"] = "Voxstead" }
            if reconsent { fields["prompt"] = "consent" }
            var parts = URLComponents(string: issuer + "/api/accounts/authorize")!
            parts.queryItems = fields.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
            return parts.url!
        }

        func callback(_ url: URL) throws -> (code: String, client: String) {
            guard url.scheme == redirect.scheme, url.host == redirect.host, url.port == redirect.port,
                  url.path == redirect.path, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                throw WorkspaceError("The sign-in callback did not match this attempt.")
            }
            let items = parts.queryItems ?? []
            guard Set(items.map(\.name)).count == items.count,
                  items.first(where: { $0.name == "state" })?.value == state else {
                throw WorkspaceError("The sign-in state did not match. Start again from Voxstead.")
            }
            if items.contains(where: { $0.name == "error" }) {
                throw WorkspaceError("Sign-in was not authorized. You can try again or use another AI provider.")
            }
            let returned = items.first(where: { $0.name == "client_id" })?.value
            guard let client = returned ?? clientID, !client.isEmpty, client != "dynamic_agent_client",
                  clientID == nil || clientID == client,
                  let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
                throw WorkspaceError("Registration was incomplete or selected a different connection. Please start again.")
            }
            return (code, client)
        }
    }

    struct Identity: Sendable { let subject: String; let email: String? }

    static func validate(_ token: String, jwks: Data, client: String, nonce: String?, now: Date = .now) throws -> Identity {
        func invalid() -> WorkspaceError { WorkspaceError("ChatGPT identity verification failed. Please sign in again.") }
        let pieces = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard pieces.count == 3, let headerData = decode(pieces[0]), let bodyData = decode(pieces[1]),
              let signature = decode(pieces[2]),
              let header = try JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              header["alg"] as? String == "RS256", header["crit"] == nil,
              let kid = header["kid"] as? String,
              let set = try JSONSerialization.jsonObject(with: jwks) as? [String: Any],
              let keys = set["keys"] as? [[String: Any]],
              let jwk = keys.first(where: { $0["kid"] as? String == kid && $0["kty"] as? String == "RSA" }),
              jwk["alg"] == nil || jwk["alg"] as? String == "RS256",
              jwk["use"] == nil || jwk["use"] as? String == "sig",
              let n = jwk["n"] as? String, let e = jwk["e"] as? String,
              let modulus = decode(n), let exponent = decode(e) else { throw invalid() }
        let der = wrap(0x30, integer(modulus) + integer(exponent))
        let attrs: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                                   kSecAttrKeyClass as String: kSecAttrKeyClassPublic]
        guard let key = SecKeyCreateWithData(der as CFData, attrs as CFDictionary, nil),
              SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256,
                                    Data((pieces[0] + "." + pieces[1]).utf8) as CFData, signature as CFData, nil),
              let body = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
              body["iss"] as? String == issuer,
              let sub = body["sub"] as? String, !sub.isEmpty,
              let exp = body["exp"] as? Double, exp > now.timeIntervalSince1970,
              let iat = body["iat"] as? Double, iat <= now.timeIntervalSince1970 + 5 else { throw invalid() }
        let audiences = (body["aud"] as? [String]) ?? (body["aud"] as? String).map { [$0] } ?? []
        guard audiences.contains(client),
              (audiences.count <= 1 && body["azp"] == nil) || body["azp"] as? String == client else { throw invalid() }
        if let nonce, body["nonce"] as? String != nonce { throw invalid() }
        if let nbf = body["nbf"] as? Double, nbf > now.timeIntervalSince1970 + 5 { throw invalid() }
        return Identity(subject: sub, email: body["email"] as? String)
    }

    private static func integer(_ data: Data) -> Data {
        var bytes = Data(data.drop(while: { $0 == 0 }))
        if bytes.isEmpty || bytes.first! >= 128 { bytes.insert(0, at: 0) }
        return wrap(0x02, bytes)
    }
    private static func wrap(_ tag: UInt8, _ content: Data) -> Data {
        var length = content.count
        var bytes: [UInt8] = []
        repeat { bytes.insert(UInt8(length & 255), at: 0); length >>= 8 } while length > 0
        let prefix: [UInt8] = content.count < 128 ? [UInt8(content.count)] : [0x80 | UInt8(bytes.count)] + bytes
        return Data([tag] + prefix) + content
    }
}

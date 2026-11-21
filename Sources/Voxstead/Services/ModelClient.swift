import Foundation
import MCP

struct ModelTool: Sendable {
    let name: String
    let description: String
    let schema: Value
}

struct ToolInvocation: Sendable {
    let id: String
    let name: String
    let arguments: [String: Value]
}

struct ModelReply: Sendable {
    let text: String
    let calls: [ToolInvocation]
}

// The thread keeps the provider's exact tool-call turn format until the answer is complete.
actor ModelClient {
    static let phoneReplySession = makeSession()
    private let profile: ProviderProfile
    private let key: String
    private let session: URLSession
    private let onPreview: (@MainActor @Sendable (String) -> Void)?
    private var messages: [[String: Any]] = []

    init(profile: ProviderProfile, key: String, session: URLSession? = nil,
         onPreview: (@MainActor @Sendable (String) -> Void)? = nil) {
        self.profile = profile
        self.key = key
        self.onPreview = onPreview
        self.session = session ?? Self.makeSession()
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 90
        configuration.timeoutIntervalForResource = 180
        return URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }

    // Listing is explicit: only the saved endpoint receives credentials, never transcripts.
    func availableModels() async throws -> [String] {
        if profile.kind == .chatGPT { return try await ChatGPTConnection.shared.models(profile.id).map(\.id) }
        guard !profile.kind.requiresKey || !key.isEmpty else {
            throw WorkspaceError("Enter your API key before browsing models.")
        }
        let endpoint = try validatedEndpoint(profile.endpoint)
        var models: Set<String> = []
        var cursor: String?
        var seenCursors: Set<String> = []
        for _ in 0..<20 {
            try Task.checkCancellation()
            var parts = URLComponents(url: endpoint.appending(path: "models"), resolvingAgainstBaseURL: false)!
            if profile.kind == .anthropic {
                parts.queryItems = (parts.queryItems ?? []) + [URLQueryItem(name: "limit", value: "1000")]
                if let cursor { parts.queryItems?.append(URLQueryItem(name: "after_id", value: cursor)) }
            }
            var request = URLRequest(url: parts.url!)
            request.timeoutInterval = 25
            if profile.kind == .anthropic {
                request.setValue(key, forHTTPHeaderField: "x-api-key")
                request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            } else if !key.isEmpty {
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let status = (response as? HTTPURLResponse)?.statusCode else {
                throw WorkspaceError("Could not read the model list. Enter a model ID manually or try again.")
            }
            guard (200..<300).contains(status) else {
                throw WorkspaceError(Self.failureMessage(status: status, provider: profile.name, listing: true))
            }
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let entries = object["data"] as? [[String: Any]] else {
                throw WorkspaceError("This provider does not return a supported model list. Enter a model ID manually.")
            }
            models.formUnion(entries.compactMap { $0["id"] as? String }.filter { !$0.isEmpty })
            guard profile.kind == .anthropic, object["has_more"] as? Bool == true else {
                return models.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            }
            guard let next = object["last_id"] as? String, !next.isEmpty, seenCursors.insert(next).inserted else {
                throw WorkspaceError("The provider could not finish listing models. Enter a model ID manually or try again.")
            }
            cursor = next
        }
        throw WorkspaceError("The provider's model list is too large. Enter a model ID manually.")
    }

    static func failureMessage(status: Int, provider: String, listing: Bool = false) -> String {
        switch status {
        case 401, 403: "\(provider) did not accept this key or its permissions. Check your API key and account access."
        case 402: "\(provider) requires available credit. Check billing in your provider account."
        case 404: listing ? "This endpoint does not list models. Check Advanced → API base URL or enter a model ID manually." : "\(provider) could not find this model or endpoint. Check the model ID and API base URL."
        case 429: "\(provider) reached a usage or rate limit. Check your allowance and try again later."
        case 500...599: "\(provider) is temporarily unavailable. Try again in a moment."
        default: "\(provider) returned HTTP \(status). Check the URL, model, and key, then try again."
        }
    }

    func reply(system: String, prompt: String, tools: [ModelTool]) async throws -> ModelReply {
        messages = [["role": "user", "content": prompt]]
        return try await send(system: system, tools: tools)
    }

    func continueReply(system: String, results: [(ToolInvocation, String)], tools: [ModelTool]) async throws -> ModelReply {
        if profile.kind == .chatGPT {
            messages += results.map { ["type": "function_call_output", "call_id": $0.0.id, "output": $0.1] }
        } else if profile.kind == .anthropic {
            messages.append(["role": "user", "content": results.map {
                ["type": "tool_result", "tool_use_id": $0.0.id, "content": $0.1]
            }])
        } else {
            messages += results.map { ["role": "tool", "tool_call_id": $0.0.id, "content": $0.1] }
        }
        return try await send(system: system, tools: tools)
    }

    private func send(system: String, tools: [ModelTool]) async throws -> ModelReply {
        try Task.checkCancellation()
        guard !profile.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WorkspaceError("Add a model ID in Settings.")
        }
        guard !profile.kind.requiresKey || !key.isEmpty else {
            throw WorkspaceError("Save the API key for \(profile.name) in Settings.")
        }
        if profile.kind == .chatGPT { return try await sendChatGPT(system: system, tools: tools) }
        let endpoint = try validatedEndpoint(profile.endpoint)
        let anthropic = profile.kind == .anthropic
        let url = endpoint.appending(path: anthropic ? "messages" : "chat/completions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["model": profile.model]
        if anthropic {
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            body["system"] = system
            body["max_tokens"] = 4096
            body["messages"] = messages
        } else {
            if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
            body["messages"] = [["role": "system", "content": system]] + messages
        }
        if !tools.isEmpty {
            body["tools"] = try tools.map { tool -> [String: Any] in
                let schema = try JSONSerialization.jsonObject(with: JSONEncoder().encode(tool.schema))
                if anthropic {
                    return ["name": tool.name, "description": tool.description, "input_schema": schema]
                }
                return ["type": "function", "function": [
                    "name": tool.name, "description": tool.description, "parameters": schema
                ]]
            }
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode else {
            throw WorkspaceError("The provider returned an unexpected response.")
        }
        guard (200..<300).contains(status) else {
            throw WorkspaceError(Self.failureMessage(status: status, provider: profile.name))
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WorkspaceError("The provider returned an unexpected format.")
        }
        let output = try anthropic ? parseAnthropic(object) : parseCompatible(object)
        if output.text.isEmpty && output.calls.isEmpty { throw WorkspaceError("The provider returned an empty response.") }
        return output
    }

    private func sendChatGPT(system: String, tools: [ModelTool]) async throws -> ModelReply {
        // The OAuth credential can only go to the public, fixed Responses route.
        let token = try await ChatGPTConnection.shared.accessToken(profile.id)
        var request = URLRequest(url: URL(string: ChatGPTIdentity.resource + "/responses")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        var body: [String: Any] = ["model": profile.model, "instructions": system, "input": messages,
                                  "store": false, "stream": true, "include": ["reasoning.encrypted_content"]]
        if !tools.isEmpty {
            body["tools"] = try tools.map { tool in
                ["type": "function", "name": tool.name, "description": tool.description,
                 "parameters": try JSONSerialization.jsonObject(with: JSONEncoder().encode(tool.schema))]
            }
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw WorkspaceError("No response from ChatGPT.") }
        guard (200..<300).contains(http.statusCode) else {
            var data = Data()
            for try await byte in bytes {
                if data.count >= 32_768 { break }
                data.append(byte)
            }
            throw ChatGPTResponseStream.failure(data: data, status: http.statusCode)
        }
        var stream = ChatGPTResponseStream()
        var preview = ""
        var lastPreview = ContinuousClock.now - .seconds(1)
        // Parse bytes instead of lines so blank SSE separators remain significant.
        var line = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            if byte == 10 {
                let value = String(decoding: line, as: UTF8.self).trimmingCharacters(in: .newlines)
                line.removeAll(keepingCapacity: true)
                let output = try stream.accept(line: value, onDelta: onPreview == nil ? nil : { preview += $0 })
                if let onPreview, !preview.isEmpty, ContinuousClock.now - lastPreview >= .milliseconds(80) {
                    lastPreview = .now
                    await onPreview(preview)
                }
                if let output {
                    let calls = try output.filter { $0["type"] as? String == "function_call" }.map { item in
                        let input = (item["arguments"] as? String).flatMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
                        return try invocation(id: item["call_id"], name: item["name"], input: input)
                    }
                    let text = output.filter { $0["type"] as? String == "message" }.flatMap {
                        $0["content"] as? [[String: Any]] ?? []
                    }.filter { $0["type"] as? String == "output_text" }.compactMap { $0["text"] as? String }.joined(separator: "\n")
                    guard !text.isEmpty || !calls.isEmpty else { throw WorkspaceError("ChatGPT returned an empty response.") }
                    messages += output
                    return ModelReply(text: text, calls: calls)
                }
            } else {
                guard line.count < 4_194_304 else { throw WorkspaceError("The ChatGPT response was too large.") }
                line.append(byte)
            }
        }
        throw WorkspaceError("ChatGPT's response was interrupted. No completed answer was saved; try again.")
    }

    private func parseAnthropic(_ object: [String: Any]) throws -> ModelReply {
        let blocks = object["content"] as? [[String: Any]] ?? []
        let calls = try blocks.filter { ($0["type"] as? String) == "tool_use" }.map { block in
            try invocation(id: block["id"], name: block["name"], input: block["input"] as? [String: Any])
        }
        messages.append(["role": "assistant", "content": blocks])
        let text = blocks.filter { ($0["type"] as? String) == "text" }
            .compactMap { $0["text"] as? String }.joined(separator: "\n")
        return ModelReply(text: text, calls: calls)
    }

    private func parseCompatible(_ object: [String: Any]) throws -> ModelReply {
        let choices = object["choices"] as? [[String: Any]]
        guard let message = choices?.first?["message"] as? [String: Any] else {
            throw WorkspaceError("The provider did not return a chat message.")
        }
        let blocks = message["tool_calls"] as? [[String: Any]] ?? []
        let calls = try blocks.map { block in
            let function = block["function"] as? [String: Any]
            let arguments = (function?["arguments"] as? String).flatMap {
                (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
            }
            return try invocation(id: block["id"], name: function?["name"], input: arguments)
        }
        let text = message["content"] as? String ?? ""
        var turn: [String: Any] = ["role": "assistant", "content": message["content"] ?? NSNull()]
        if !blocks.isEmpty { turn["tool_calls"] = blocks }
        // Some compatible endpoints require opaque vendor metadata on subsequent tool turns.
        if let details = message["reasoning_details"] { turn["reasoning_details"] = details }
        messages.append(turn)
        return ModelReply(text: text, calls: calls)
    }

    private func invocation(id: Any?, name: Any?, input: [String: Any]?) throws -> ToolInvocation {
        guard let id = id as? String, let name = name as? String, let input else {
            throw WorkspaceError("The provider returned an invalid tool call.")
        }
        let data = try JSONSerialization.data(withJSONObject: input)
        let arguments = try JSONDecoder().decode([String: Value].self, from: data)
        return ToolInvocation(id: id, name: name, arguments: arguments)
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

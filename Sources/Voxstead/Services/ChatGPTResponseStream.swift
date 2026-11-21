import Foundation

/// Only a completed response is committed. Deltas may precede a late limit error.
struct ChatGPTResponseStream {
    private var eventData = ""
    private var bytes = 0

    mutating func accept(line: String, onDelta: ((String) -> Void)? = nil) throws -> [[String: Any]]? {
        bytes += line.utf8.count
        guard bytes <= 16_777_216 else { throw WorkspaceError("The ChatGPT response was too large.") }
        if line.hasPrefix("data:") {
            let value = line.dropFirst(5)
            eventData += String(value.first == " " ? value.dropFirst() : value) + "\n"
            return nil
        }
        guard line.isEmpty, !eventData.isEmpty else { return nil }
        defer { eventData = "" }
        guard let event = try JSONSerialization.jsonObject(with: Data(eventData.utf8)) as? [String: Any],
              let type = event["type"] as? String else { throw WorkspaceError("ChatGPT returned an invalid stream event.") }
        let response = event["response"] as? [String: Any] ?? [:]
        switch type {
        case "response.output_text.delta":
            if let delta = event["delta"] as? String { onDelta?(delta) }
            return nil
        case "response.completed":
            guard response["status"] as? String == "completed", let output = response["output"] as? [[String: Any]] else {
                throw WorkspaceError("ChatGPT did not finish the response.")
            }
            return output
        case "response.failed", "response.incomplete", "error":
            let error = response["error"] as? [String: Any] ?? event["error"] as? [String: Any] ?? event
            throw failure(code: error["code"] as? String, status: nil)
        default: return nil
        }
    }

    static func failure(data: Data, status: Int) -> WorkspaceError {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return failure(code: (object?["error"] as? [String: Any])?["code"] as? String, status: status)
    }
    static func failure(code: String?, status: Int?) -> WorkspaceError {
        if code == "subscription_sharing_usage_limit_exceeded" || status == 429 {
            return WorkspaceError("ChatGPT usage limit reached. Open Manage usage to review your plan or app limit. Voxstead has not switched to paid API usage.")
        }
        if code == "subscription_sharing_user_not_eligible" {
            return WorkspaceError("This ChatGPT account or workspace is not eligible to use its plan here. Choose another connection.")
        }
        if status == 401 { return WorkspaceError("ChatGPT did not accept this session. Reconnect in Settings → AI providers.") }
        if status == 403 { return WorkspaceError("ChatGPT plan access was not allowed for this request. Check the account, permissions, and region.") }
        if code == "subscription_sharing_unsupported_capability" {
            return WorkspaceError("This feature or model is not available with your ChatGPT plan. Choose another model or provider.")
        }
        return WorkspaceError("ChatGPT could not complete the response\(status.map { " (HTTP \($0))" } ?? ""). Try again later. Your billing source has not changed.")
    }
    private func failure(code: String?, status: Int?) -> WorkspaceError { Self.failure(code: code, status: status) }
}

import Darwin
import Foundation
import MCP

actor MCPConnection {
    private let client = Client(name: "Voxstead", version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development")
    private var process: Process?
    private var pipes: [Pipe] = []
    private var isClosed = false

    func connect(_ profile: ServerProfile, token: String) async throws {
        let transport: any Transport
        switch profile.transport {
        case .http:
            let url = try validatedEndpoint(profile.address)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 20
            configuration.timeoutIntervalForResource = 40
            transport = HTTPClientTransport(
                endpoint: url, configuration: configuration, streaming: false,
                requestModifier: { request in
                    var request = request
                    if request.url?.host == url.host, !token.isEmpty {
                        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                    }
                    return request
                }
            )
        case .stdio:
            guard profile.address.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: profile.address) else {
                throw WorkspaceError("Enter the absolute path of a local executable.")
            }
            let input = Pipe()
            let output = Pipe()
            let child = Process()
            child.executableURL = URL(fileURLWithPath: profile.address)
            child.arguments = profile.arguments
            child.standardInput = input
            child.standardOutput = output
            child.standardError = FileHandle.nullDevice
            var environment = ProcessInfo.processInfo.environment.filter {
                ["HOME", "USER", "LOGNAME", "LANG", "LC_ALL", "TMPDIR"].contains($0.key)
            }
            environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
            if let name = profile.environmentName, !token.isEmpty { environment[name] = token }
            child.environment = environment
            guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
                throw WorkspaceError("Could not set up the MCP server pipe.")
            }
            try child.run()
            process = child
            pipes = [input, output]
            transport = StdioTransport(
                input: .init(rawValue: output.fileHandleForReading.fileDescriptor),
                output: .init(rawValue: input.fileHandleForWriting.fileDescriptor)
            )
        }
        _ = try await bounded { [client] in try await client.connect(transport: transport) }
    }

    func list() async throws -> [MCP.Tool] {
        try await bounded { [client] in
            var tools: [MCP.Tool] = []
            var cursor: String?
            var seen: Set<String> = []
            repeat {
                let result = try await client.listTools(cursor: cursor)
                tools += result.tools
                cursor = result.nextCursor
                if let cursor, !seen.insert(cursor).inserted {
                    throw WorkspaceError("The MCP server repeated a tools cursor.")
                }
                if tools.count > 128 || seen.count > 20 {
                    throw WorkspaceError("The server exceeded the tool discovery limit.")
                }
            } while cursor != nil
            return tools
        }
    }

    func call(_ name: String, arguments: [String: Value]) async throws -> String {
        try await bounded { [client] in
            let request = CallTool.request(.init(name: name, arguments: arguments))
            let context = try await client.send(request)
            let result = try await context.value
            let text = result.content.compactMap { item -> String? in
                guard case .text(let value, _, _) = item else { return nil }
                return value
            }.joined(separator: "\n")
            let structured = try result.structuredContent.map {
                String(decoding: try JSONEncoder().encode($0), as: UTF8.self)
            }
            let contents = [text.isEmpty ? nil : text, structured].compactMap { $0 }.joined(separator: "\n")
            let status = result.isError == true ? "The tool reported an error.\n" : ""
            let excerpt = String(contents.prefix(16_000))
            return status + (excerpt.isEmpty ? "No text result." : excerpt)
                + (contents.count > 16_000 ? "\n[Truncated result]" : "")
        }
    }

    func close() async {
        guard !isClosed else { return }
        isClosed = true
        await client.disconnect()
        if let process, process.isRunning { process.terminate() }
        for pipe in pipes {
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
        }
        pipes = []
        process = nil
    }

    private func bounded<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: T.self) { group in
                group.addTask { try await operation() }
                group.addTask {
                    try await Task.sleep(for: .seconds(45))
                    await self.close()
                    throw WorkspaceError("The MCP server timed out.")
                }
                defer { group.cancelAll() }
                guard let value = try await group.next() else { throw CancellationError() }
                return value
            }
        } onCancel: {
            Task { await self.close() }
        }
    }
}

import Foundation
import Darwin

/// Coordinates rotating Keychain credentials across multiple local app instances.
final class ChatGPTCredentialLock: @unchecked Sendable {
    private let descriptor: Int32
    private init(_ descriptor: Int32) { self.descriptor = descriptor }
    deinit { flock(descriptor, LOCK_UN); close(descriptor) }

    static func acquire(_ id: UUID) async throws -> ChatGPTCredentialLock {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Voxstead/ConnectionLocks", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let descriptor = open(directory.appending(path: id.uuidString + ".lock").path,
                              O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw WorkspaceError("Could not protect the ChatGPT connection. Try again.") }
        do {
            for _ in 0..<1800 {
                try Task.checkCancellation()
                if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { return ChatGPTCredentialLock(descriptor) }
                guard errno == EWOULDBLOCK else { throw WorkspaceError("Could not lock the ChatGPT connection.") }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw WorkspaceError("Another Voxstead window is updating this connection. Try again shortly.")
        } catch { close(descriptor); throw error }
    }
}

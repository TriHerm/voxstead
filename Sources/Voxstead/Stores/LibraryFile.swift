import Foundation

struct LibraryFile {
    let url: URL

    static let userLibrary = LibraryFile(
        url: URL.applicationSupportDirectory
            .appending(path: "Voxstead", directoryHint: .isDirectory)
            .appending(path: "library.json")
    )

    static func migratePreviewIfNeeded() throws {
        let target = userLibrary
        let original = LibraryFile(url: URL.applicationSupportDirectory.appending(path: "CluinnOSS/library.json"))
        guard !FileManager.default.fileExists(atPath: target.url.path),
              FileManager.default.fileExists(atPath: original.url.path) else { return }
        try target.save(original.load())
    }

    func load() throws -> WorkspaceDocument {
        do { return try JSONDecoder().decode(WorkspaceDocument.self, from: Data(contentsOf: url)) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return WorkspaceDocument() }
    }

    static func readBackup(_ url: URL) throws -> WorkspaceDocument {
        let document = try JSONDecoder().decode(WorkspaceDocument.self, from: Data(contentsOf: url))
        guard Set(document.sessions.map(\.id)).count == document.sessions.count else {
            throw WorkspaceError("The backup contains duplicate sessions.")
        }
        return document
    }

    func restore(_ document: WorkspaceDocument) throws -> URL? {
        let fileManager = FileManager.default
        var archive: URL?
        if fileManager.fileExists(atPath: url.path) {
            let folder = url.deletingLastPathComponent().appending(path: "Library Recovery", directoryHint: .isDirectory)
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
            let original = folder.appending(path: "library-\(UUID().uuidString).json")
            try fileManager.copyItem(at: url, to: original)
            archive = original
        }
        try save(document)
        return archive
    }

    func save(_ document: WorkspaceDocument) throws {
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        try JSONEncoder().encode(document).write(to: url, options: .atomic)
    }
}

import Foundation

/// Loads and saves the `SpaciousDocument` as JSON on disk.
public struct LayoutStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// `~/Library/Application Support/Spacious/layouts.json`
    public static var defaultFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Spacious", isDirectory: true).appendingPathComponent("layouts.json")
    }

    /// Returns the saved document, or a fresh default one if nothing is saved
    /// yet. A corrupt file is moved aside instead of being overwritten.
    public func load() -> SpaciousDocument {
        guard let data = try? Data(contentsOf: fileURL) else { return SpaciousDocument() }
        do {
            return try JSONDecoder().decode(SpaciousDocument.self, from: data)
        } catch {
            let backup = fileURL.deletingPathExtension().appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: fileURL, to: backup)
            return SpaciousDocument()
        }
    }

    public func save(_ document: SpaciousDocument) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(document).write(to: fileURL, options: .atomic)
    }
}

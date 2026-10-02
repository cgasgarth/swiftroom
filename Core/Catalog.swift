import Foundation

struct HistoryEntry: Codable, Equatable, Identifiable, Sendable {
    var id: UUID = UUID()
    var date: Date = Date()
    var label: String
    var edits: EditState
}

struct PhotoDocument: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var fileName: String
    var originalSourcePath: String
    var relativeOriginalPath: String
    var metadata: PhotoMetadata
    var edits: EditState
    var history: [HistoryEntry]
    var historyIndex: Int
    var savedEdits: EditState
    var rating: Int = 0
    var isRejected: Bool = false
    var importedAt: Date = Date()

    var isDirty: Bool { edits != savedEdits }
    var canUndo: Bool { historyIndex > 0 }
    var canRedo: Bool { historyIndex + 1 < history.count }

    mutating func commit(_ state: EditState, label: String) {
        guard state != history[historyIndex].edits else { edits = state; return }
        history = Array(history.prefix(historyIndex + 1))
        history.append(HistoryEntry(label: label, edits: state))
        historyIndex = history.count - 1
        edits = state
    }

    mutating func undo() {
        guard canUndo else { return }
        historyIndex -= 1
        edits = history[historyIndex].edits
    }

    mutating func redo() {
        guard canRedo else { return }
        historyIndex += 1
        edits = history[historyIndex].edits
    }

    mutating func restoreHistory(at index: Int) {
        guard history.indices.contains(index) else { return }
        historyIndex = index
        edits = history[index].edits
    }
}

struct PhotoCatalog: Codable, Sendable {
    var schemaVersion: Int = 2
    var id: UUID = UUID()
    var createdAt: Date = Date()
    var documents: [PhotoDocument] = []
    var selectedAssetID: UUID?
    var library: LibraryCatalog?
}

enum CatalogError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self {
        case .invalid(let text): return text
        }
    }
}

struct CatalogRepository: Sendable {
    let rootURL: URL
    var catalogURL: URL { rootURL.appendingPathComponent("catalog.json") }
    var cacheURL: URL { rootURL.appendingPathComponent("Cache", isDirectory: true) }

    func prepare() throws {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: rootURL.appendingPathComponent("Originals"), withIntermediateDirectories: true)
    }

    func load() throws -> PhotoCatalog {
        try prepare()
        guard FileManager.default.fileExists(atPath: catalogURL.path) else { return PhotoCatalog() }
        let data = try Data(contentsOf: catalogURL)
        let header = try JSONDecoder().decode(CatalogHeader.self, from: data)
        guard header.schemaVersion == 2 else {
            throw CatalogError.invalid("This catalog uses an unsupported version.")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        let catalog = try decoder.decode(PhotoCatalog.self, from: data)
        guard Set(catalog.documents.map(\.id)).count == catalog.documents.count else {
            throw CatalogError.invalid("The catalog contains duplicate photo identifiers.")
        }
        for document in catalog.documents {
            guard !document.history.isEmpty, document.history.indices.contains(document.historyIndex) else {
                throw CatalogError.invalid("The history for \(document.fileName) is damaged.")
            }
            _ = try sourceURL(for: document)
        }
        return catalog
    }

    func save(_ catalog: PhotoCatalog) throws {
        try prepare()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .deferredToDate
        try encoder.encode(catalog).write(to: catalogURL, options: .atomic)
    }

    func sourceURL(for document: PhotoDocument) throws -> URL {
        let relative = document.relativeOriginalPath
        guard relative.hasPrefix("Originals/"), !relative.split(separator: "/").contains(".."),
              !relative.hasPrefix("/") else {
            throw CatalogError.invalid("The catalog contains an unsafe original path.")
        }
        let url = rootURL.appendingPathComponent(relative).standardizedFileURL
        guard url.path.hasPrefix(rootURL.standardizedFileURL.path + "/Originals/") else {
            throw CatalogError.invalid("The original is outside this catalog.")
        }
        return url
    }

    func copyOriginal(from source: URL, id: UUID) throws -> String {
        let directory = rootURL.appendingPathComponent("Originals/\(id.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(source.lastPathComponent)
        do {
            try FileManager.default.copyItem(at: source, to: destination)
            let sidecarCandidates = [
                URL(fileURLWithPath: source.path + ".xmp"),
                source.deletingPathExtension().appendingPathExtension("xmp")
            ]
            if let sidecar = sidecarCandidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
                try FileManager.default.copyItem(at: sidecar, to: URL(fileURLWithPath: destination.path + ".xmp"))
            }
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        return "Originals/\(id.uuidString)/\(source.lastPathComponent)"
    }
}

private struct CatalogHeader: Decodable {
    var schemaVersion: Int
}

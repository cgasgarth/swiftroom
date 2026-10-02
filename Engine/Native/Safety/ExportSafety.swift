import Foundation

enum ExportSafety {
    static func validate(source: URL, destination: URL) throws {
        let resolvedSource = source.resolvingSymlinksInPath().standardizedFileURL
        let resolvedDestination = destination.resolvingSymlinksInPath().standardizedFileURL
        if resolvedSource == resolvedDestination {
            throw PhotoEngineError.unsupported("Export cannot replace an original image.")
        }
        if let sourceIdentity = try identity(resolvedSource),
           let destinationIdentity = try identity(resolvedDestination), sourceIdentity == destinationIdentity {
            throw PhotoEngineError.unsupported("Export destination refers to the original image.")
        }
    }

    private static func identity(_ url: URL) throws -> FileIdentity? {
        let manager = FileManager.default
        guard manager.fileExists(atPath: url.path) else { return nil }
        let attributes = try manager.attributesOfItem(atPath: url.path)
        guard let volume = attributes[.systemNumber] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber else {
            throw PhotoEngineError.processing("Cannot verify export destination file identity.")
        }
        return FileIdentity(volume: volume.uint64Value, inode: inode.uint64Value)
    }
}

private struct FileIdentity: Equatable {
    var volume: UInt64
    var inode: UInt64
}

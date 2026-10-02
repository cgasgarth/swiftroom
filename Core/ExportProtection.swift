import Foundation

struct ExportOverwriteAuthorization: Equatable, Sendable {
    let volume: UInt64
    let inode: UInt64
    let size: UInt64
    let modificationDate: Date

    static func capture(destination: URL) throws -> ExportOverwriteAuthorization {
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.resolvingSymlinksInPath().path)
        guard let volume = attributes[.systemNumber] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber,
              let size = attributes[.size] as? NSNumber,
              let modificationDate = attributes[.modificationDate] as? Date,
              attributes[.type] as? FileAttributeType == .typeRegular else {
            throw PhotoEngineError.processing("Cannot authorize replacement of this export destination.")
        }
        return Self(volume: volume.uint64Value, inode: inode.uint64Value,
                    size: size.uint64Value, modificationDate: modificationDate)
    }
}

enum ExportProtection {
    static func validate(_ request: ExportRequest) throws {
        try validateOriginals(request)
        let destination = request.destinationURL.resolvingSymlinksInPath().standardizedFileURL
        if FileManager.default.fileExists(atPath: destination.path) {
            guard let authorization = request.overwriteAuthorization,
                  try ExportOverwriteAuthorization.capture(destination: destination) == authorization else {
                throw PhotoEngineError.unsupported("The export destination exists or changed. Confirm its replacement.")
            }
        } else if request.overwriteAuthorization != nil {
            throw PhotoEngineError.unsupported("The authorized export destination changed. Choose it again.")
        }
    }

    static func validateOriginals(_ request: ExportRequest) throws {
        let destination = request.destinationURL.resolvingSymlinksInPath().standardizedFileURL
        let sources = request.protectedSourceURLs + [request.sourceURL]
        let destinationIdentity = try identity(destination)
        for catalog in request.protectedCatalogURLs {
            let resolved = catalog.resolvingSymlinksInPath().standardizedFileURL
            let catalogIdentity = try identity(resolved)
            if resolved == destination || (destinationIdentity != nil && catalogIdentity == destinationIdentity) {
                throw PhotoEngineError.unsupported("Export cannot replace a catalog file.")
            }
        }
        for source in sources {
            let resolved = source.resolvingSymlinksInPath().standardizedFileURL
            let sourceIdentity = try identity(resolved)
            if resolved == destination || (destinationIdentity != nil && sourceIdentity == destinationIdentity) {
                throw PhotoEngineError.unsupported("Export cannot replace an original image.")
            }
        }
        for directory in request.protectedDirectories {
            guard let protectedIdentity = try identity(directory.resolvingSymlinksInPath()) else { continue }
            var ancestor = destination
            while true {
                if try identity(ancestor) == protectedIdentity {
                    throw PhotoEngineError.unsupported("Choose an export location outside catalog originals.")
                }
                let parent = ancestor.deletingLastPathComponent()
                if parent.path == ancestor.path { break }
                ancestor = parent
            }
        }
    }

    private static func identity(_ url: URL) throws -> [UInt64]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let volume = attributes[.systemNumber] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber else {
            throw PhotoEngineError.processing("Cannot verify export destination file identity.")
        }
        return [volume.uint64Value, inode.uint64Value]
    }
}

import Foundation

enum ExportDestination {
    static func validate(folder: URL, fileName: String, format: ExportFormat) throws -> URL {
        guard folder.isFileURL else { throw ExportPresentationError.invalid("Choose a local export folder.") }
        guard !fileName.isEmpty, fileName != ".", fileName != "..",
              !fileName.contains("/"),
              !fileName.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ExportPresentationError.invalid("Enter a filename without slashes or control characters.")
        }
        guard fileName.utf8.count <= 255 else {
            throw ExportPresentationError.invalid("The filename is too long for this folder.")
        }
        guard format.accepts(extension: URL(fileURLWithPath: fileName).pathExtension) else {
            throw ExportPresentationError.invalid("Use \(format.extensionDescription) for \(format.displayName).")
        }
        let values = try folder.resourceValues(forKeys: [.isDirectoryKey, .isWritableKey])
        guard values.isDirectory == true, values.isWritable == true else {
            throw ExportPresentationError.invalid("Choose an existing folder that you can write to.")
        }
        let destination = folder.appendingPathComponent(fileName, isDirectory: false)
        if FileManager.default.fileExists(atPath: destination.path) {
            let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                throw ExportPresentationError.invalid("Choose a regular file or a new filename.")
            }
        }
        return destination
    }

    static func name(_ fileName: String, changingTo format: ExportFormat) -> String {
        let url = URL(fileURLWithPath: fileName)
        if format.accepts(extension: url.pathExtension) { return fileName }
        let base = ExportFormat.allCases.contains { $0.accepts(extension: url.pathExtension) }
            ? url.deletingPathExtension().lastPathComponent : fileName
        return base + "." + format.fileExtension
    }
}

enum ExportPresentationError: LocalizedError {
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        }
    }
}

extension ExportFormat {
    var displayName: String {
        switch self {
        case .jpeg: return "JPEG"
        case .png: return "PNG"
        case .tiff: return "TIFF"
        }
    }

    var extensionDescription: String {
        switch self {
        case .jpeg: return ".jpg or .jpeg"
        case .png: return ".png"
        case .tiff: return ".tif or .tiff"
        }
    }

    func accepts(extension value: String) -> Bool {
        switch self {
        case .jpeg: return ["jpg", "jpeg"].contains(value.lowercased())
        case .png: return value.lowercased() == "png"
        case .tiff: return ["tif", "tiff"].contains(value.lowercased())
        }
    }
}

extension ExportColorSpace {
    var displayName: String {
        switch self {
        case .sRGB: return "sRGB"
        case .displayP3: return "Display P3"
        case .adobeRGB: return "Adobe RGB (compatible)"
        }
    }
}

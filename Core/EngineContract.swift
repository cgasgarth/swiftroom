import Foundation

struct PhotoMetadata: Codable, Equatable, Sendable {
    var pixelWidth: Int
    var pixelHeight: Int
    var camera: String?
    var lens: String?
    var captureDate: Date?
    var iso: Int?
    var shutter: String?
    var aperture: String?
    static let unknown = PhotoMetadata(pixelWidth: 0, pixelHeight: 0)
}

struct ModuleState: Codable, Equatable, Identifiable, Sendable {
    var id: UUID = UUID()
    var operation: String
    var version: Int
    var instance: Int
    var enabled: Bool
    var order: Double
    var parameters: Data
    var blendParameters: Data?
    var blendVersion: Int?
    var name: String?
}

struct EditState: Codable, Equatable, Sendable {
    var exposureEV: Double = 0
    var temperature: Double?
    var tint: Double = 0
    var modules: [ModuleState] = []
    var darktableXMP: Data?
    static let original = EditState()
}

struct EngineCapabilities: Sendable {
    var name: String
    var revision: String
    var supportsExposure: Bool
    var supportsWhiteBalance: Bool
    var supportsModuleEditing: Bool
    var supportsFullResolutionExport: Bool
    var limitations: [String]
}

struct RenderRequest: Sendable {
    var assetID: UUID
    var generation: UInt64
    var sourceURL: URL
    var edits: EditState
    var maximumDimension: Int
}

struct PreparedPhoto: Sendable {
    var metadata: PhotoMetadata
    var edits: EditState
}

struct RenderedPhoto: Sendable {
    var assetID: UUID
    var generation: UInt64
    var imageURL: URL
    var pixelWidth: Int
    var pixelHeight: Int
    var colorSpaceName: String
    var engineRevision: String
}

enum ExportFormat: String, Codable, CaseIterable, Sendable {
    case jpeg, png, tiff
    var fileExtension: String { self == .jpeg ? "jpg" : rawValue }
}

enum ExportColorSpace: String, Codable, CaseIterable, Sendable {
    case sRGB, displayP3, adobeRGB
}

struct ExportRequest: Sendable {
    var assetID: UUID
    var sourceURL: URL
    var edits: EditState
    var destinationURL: URL
    var format: ExportFormat
    var colorSpace: ExportColorSpace
    var quality: Double
    var maximumDimension: Int?
}

struct ExportResult: Sendable {
    var destinationURL: URL
    var pixelWidth: Int
    var pixelHeight: Int
    var colorSpaceName: String
}

protocol PhotoEngine: Sendable {
    var capabilities: EngineCapabilities { get }
    func inspect(sourceURL: URL) async throws -> PhotoMetadata
    func prepare(sourceURL: URL, edits: EditState) async throws -> PreparedPhoto
    func render(_ request: RenderRequest) async throws -> RenderedPhoto
    func export(_ request: ExportRequest) async throws -> ExportResult
    func modules() async throws -> [ProcessingModule]
    func schema(for operation: String) async throws -> ModuleSchema
    func parameters(for module: ModuleState) async throws -> [String: ModuleParameterValue]
    func updating(module: ModuleState, values: [String: ModuleParameterValue]) async throws -> ModuleState
}

extension PhotoEngine {
    func prepare(sourceURL: URL, edits: EditState) async throws -> PreparedPhoto {
        PreparedPhoto(metadata: try await inspect(sourceURL: sourceURL), edits: edits)
    }
}

enum PhotoEngineError: LocalizedError {
    case unavailable(String), unsupported(String), processing(String), invalidOutput(String)
    var errorDescription: String? {
        switch self {
        case .unavailable(let text), .unsupported(let text), .processing(let text), .invalidOutput(let text):
            return text
        }
    }
}

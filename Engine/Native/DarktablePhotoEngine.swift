import Foundation
import ImageIO

enum NativePhotoEngineFactory {
    static func make(cacheDirectory: URL) -> any PhotoEngine {
        DarktablePhotoEngine(cacheDirectory: cacheDirectory, runtime: EngineRuntime.locate())
    }
}

actor DarktablePhotoEngine: PhotoEngine {
    nonisolated let capabilities: EngineCapabilities
    private let cacheDirectory: URL
    private let runtime: EngineRuntime?
    private let process = HelperProcess()
    var moduleList: [ProcessingModule]?
    var moduleSchemas: [String: ModuleSchema] = [:]

    init(cacheDirectory: URL, runtime: EngineRuntime?) {
        self.cacheDirectory = cacheDirectory
        self.runtime = runtime
        capabilities = EngineCapabilities(
            name: "darktable", revision: "5.6.0 / 3c17b2976793",
            supportsExposure: runtime != nil, supportsWhiteBalance: runtime != nil,
            supportsModuleEditing: runtime != nil, supportsFullResolutionExport: runtime != nil,
            limitations: [
                "Scalar parameters are editable; curves and compound arrays remain preserved in opaque blobs.",
                "Native drawn-mask and blending controls remain incomplete.",
                "CPU processing; OpenCL acceleration remains disabled during validation.",
                "White balance uses the camera matrix and darktable's temperature spectral conversion."
            ]
        )
    }

    func inspect(sourceURL: URL) async throws -> PhotoMetadata {
        try await prepare(sourceURL: sourceURL, edits: .original).metadata
    }

    func prepare(sourceURL: URL, edits: EditState) async throws -> PreparedPhoto {
        let result = try await execute(sourceURL: sourceURL, edits: edits, maximumDimension: 0, command: "prepare")
        var prepared = edits
        prepared.modules = result.response.modules.map(\.state)
        prepared.darktableXMP = result.response.darktableXMP
        prepared.exposureEV = 0
        prepared.temperature = nil
        prepared.tint = 0
        return PreparedPhoto(metadata: result.response.metadata, edits: prepared)
    }

    func render(_ request: RenderRequest) async throws -> RenderedPhoto {
        let result = try await execute(
            sourceURL: request.sourceURL, edits: request.edits,
            maximumDimension: request.maximumDimension, command: "render"
        )
        let dimensions = try validate(result.output)
        return RenderedPhoto(
            assetID: request.assetID, generation: request.generation, imageURL: result.output,
            pixelWidth: dimensions.width, pixelHeight: dimensions.height, colorSpaceName: "sRGB",
            engineRevision: capabilities.revision
        )
    }

    func export(_ request: ExportRequest) async throws -> ExportResult {
        try ExportSafety.validate(source: request.sourceURL, destination: request.destinationURL)
        let result = try await execute(
            sourceURL: request.sourceURL, edits: request.edits, maximumDimension: request.maximumDimension ?? 0,
            command: "render", format: request.format, colorSpace: request.colorSpace, quality: request.quality
        )
        let dimensions = try validate(result.output)
        try Task.checkCancellation()
        try ExportSafety.validate(source: request.sourceURL, destination: request.destinationURL)
        let manager = FileManager.default
        if manager.fileExists(atPath: request.destinationURL.path) {
            _ = try manager.replaceItemAt(request.destinationURL, withItemAt: result.output)
        } else {
            try manager.moveItem(at: result.output, to: request.destinationURL)
        }
        return ExportResult(
            destinationURL: request.destinationURL, pixelWidth: dimensions.width,
            pixelHeight: dimensions.height, colorSpaceName: request.colorSpace.rawValue
        )
    }

    private func execute(
        sourceURL: URL, edits: EditState, maximumDimension: Int, command: String,
        format: ExportFormat = .png, colorSpace: ExportColorSpace = .sRGB, quality: Double = 0.95
    ) async throws -> (response: HelperWireResponse, output: URL) {
        guard let runtime else {
            throw PhotoEngineError.unavailable("Build the darktable helper before opening a photo.")
        }
        try Task.checkCancellation()
        let manager = FileManager.default
        let directory = cacheDirectory.appendingPathComponent("Requests/\(UUID().uuidString)")
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("input.\(sourceURL.pathExtension)")
        try manager.copyItem(at: sourceURL, to: source)
        var xmp = edits.darktableXMP
        let sourceSidecar = URL(fileURLWithPath: sourceURL.path + ".xmp")
        if command == "prepare", xmp == nil, manager.fileExists(atPath: sourceSidecar.path) {
            xmp = try Data(contentsOf: sourceSidecar)
        }
        let history = directory.appendingPathComponent("history.xmp")
        if let xmp { try xmp.write(to: history, options: .atomic) }
        let output = directory.appendingPathComponent("render.\(format.fileExtension)")
        var orderedEdits = edits
        orderedEdits.modules.sort { $0.order < $1.order }
        let wire = HelperWireRequest(
            source: source.path, xmp: xmp == nil ? nil : history.path, edits: orderedEdits,
            destination: output.path, format: format == .jpeg ? "jpeg" : format.rawValue,
            colorSpace: colorSpace.rawValue, maximumDimension: max(0, maximumDimension),
            quality: Int((min(1, max(0, quality)) * 100).rounded())
        )
        let request = directory.appendingPathComponent("request.json")
        let response = directory.appendingPathComponent("response.json")
        let log = directory.appendingPathComponent("helper.log")
        try JSONEncoder().encode(wire).write(to: request, options: .atomic)
        do {
            try await process.run(
                executable: runtime.executable,
                arguments: runtime.arguments(
                    command: command, request: request, response: response, directory: directory
                ),
                logURL: log
            )
            let result = try JSONDecoder().decode(HelperWireResponse.self, from: Data(contentsOf: response))
            try? manager.removeItem(at: source)
            return (result, output)
        } catch {
            let message = (try? String(contentsOf: log, encoding: .utf8)) ?? error.localizedDescription
            try? manager.removeItem(at: directory)
            if Task.isCancelled { throw CancellationError() }
            throw PhotoEngineError.processing(String(message.suffix(2_000)))
        }
    }

    private func validate(_ url: URL) throws -> (width: Int, height: Int) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              properties[kCGImagePropertyProfileName] != nil,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width > 0, image.height > 0, image.colorSpace?.copyICCData() != nil else {
            throw PhotoEngineError.invalidOutput("darktable did not produce a decodable ICC-tagged image.")
        }
        return (image.width, image.height)
    }

    func query<Input: Encodable & Sendable, Output: Decodable & Sendable>(
        _ command: String, input: Input
    ) async throws -> Output {
        guard let runtime else { throw PhotoEngineError.unavailable("darktable helper unavailable.") }
        let directory = cacheDirectory.appendingPathComponent("Queries/\(UUID().uuidString)")
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let request = directory.appendingPathComponent("request.json")
        let response = directory.appendingPathComponent("response.json")
        let log = directory.appendingPathComponent("helper.log")
        try JSONEncoder().encode(input).write(to: request, options: .atomic)
        do {
            try await process.run(
                executable: runtime.executable,
                arguments: runtime.arguments(
                    command: command, request: request, response: response, directory: directory
                ),
                logURL: log
            )
            let output = try JSONDecoder().decode(Output.self, from: Data(contentsOf: response))
            try? manager.removeItem(at: directory)
            return output
        } catch {
            let message = (try? String(contentsOf: log, encoding: .utf8)) ?? error.localizedDescription
            try? manager.removeItem(at: directory)
            if Task.isCancelled { throw CancellationError() }
            throw PhotoEngineError.processing(String(message.suffix(2_000)))
        }
    }
}

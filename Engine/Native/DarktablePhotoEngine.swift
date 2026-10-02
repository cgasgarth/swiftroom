import Foundation

enum NativePhotoEngineFactory {
    static func make(cacheDirectory: URL) -> any PhotoEngine {
        DarktablePhotoEngine(cacheDirectory: cacheDirectory, resolution: Result { try EngineRuntime.locate() })
    }
}

actor DarktablePhotoEngine: PhotoEngine {
    nonisolated let capabilities: EngineCapabilities
    private let cacheDirectory: URL
    private let runtime: EngineRuntime?
    private let runtimeFailure: String
    private let process = HelperProcess()
    private var previews: Set<URL> = []
    var moduleList: [ProcessingModule]?
    var moduleSchemas: [String: ModuleSchema] = [:]

    init(cacheDirectory: URL, resolution: Result<EngineRuntime, any Error>) {
        self.cacheDirectory = cacheDirectory
        switch resolution {
        case .success(let runtime):
            self.runtime = runtime
            runtimeFailure = ""
        case .failure(let error):
            runtime = nil
            runtimeFailure = error.localizedDescription
        }
        capabilities = EngineCapabilities(
            name: "darktable", revision: "5.6.0 / 3c17b2976793",
            supportsExposure: runtime != nil, supportsWhiteBalance: runtime != nil,
            supportsModuleEditing: runtime != nil, supportsFullResolutionExport: runtime != nil,
            limitations: [
                "Scalar parameters are editable; curves and compound arrays remain preserved in opaque blobs.",
                "Native drawn-mask and blending controls remain incomplete.",
                "CPU processing; OpenCL acceleration remains disabled during validation.",
                "White balance uses the camera matrix and darktable's temperature spectral conversion."
            ], supportedExportFormats: runtime == nil ? [] : [.jpeg, .png, .tiff],
            supportedExportColorSpaces: runtime == nil ? [] : [.sRGB, .displayP3, .adobeRGB]
        )
    }

    func inspect(sourceURL: URL) async throws -> PhotoMetadata {
        try await prepare(sourceURL: sourceURL, edits: .original).metadata
    }

    func prepare(sourceURL: URL, edits: EditState) async throws -> PreparedPhoto {
        let result = try await execute(sourceURL: sourceURL, edits: edits, maximumDimension: 0, command: "prepare")
        defer { try? FileManager.default.removeItem(at: result.directory) }
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
        defer { try? FileManager.default.removeItem(at: result.directory) }
        let dimensions = try ImageValidation.validate(result.output, expectedICC: result.response.outputICC)
        try Task.checkCancellation()
        let directory = cacheDirectory.appendingPathComponent("Previews")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let preview = directory.appendingPathComponent("\(UUID().uuidString).png")
        try FileManager.default.moveItem(at: result.output, to: preview)
        previews.insert(preview)
        return RenderedPhoto(
            assetID: request.assetID, generation: request.generation, imageURL: preview,
            pixelWidth: dimensions.width, pixelHeight: dimensions.height, colorSpaceName: dimensions.profileName,
            engineRevision: capabilities.revision
        )
    }

    func release(_ photo: RenderedPhoto) async {
        guard previews.remove(photo.imageURL) != nil else { return }
        try? FileManager.default.removeItem(at: photo.imageURL)
    }

    func export(_ request: ExportRequest) async throws -> ExportResult {
        try ExportProtection.validate(request)
        let result = try await execute(
            sourceURL: request.sourceURL, edits: request.edits, maximumDimension: request.maximumDimension ?? 0,
            command: "render", format: request.format, colorSpace: request.colorSpace, quality: request.quality
        )
        defer { try? FileManager.default.removeItem(at: result.directory) }
        let dimensions = try ImageValidation.validate(result.output, expectedICC: result.response.outputICC)
        try Task.checkCancellation()
        try ExportProtection.validate(request)
        try Task.checkCancellation()
        let manager = FileManager.default
        if manager.fileExists(atPath: request.destinationURL.path) {
            _ = try manager.replaceItemAt(request.destinationURL, withItemAt: result.output)
        } else {
            try manager.moveItem(at: result.output, to: request.destinationURL)
        }
        return ExportResult(
            destinationURL: request.destinationURL, pixelWidth: dimensions.width,
            pixelHeight: dimensions.height, colorSpaceName: dimensions.profileName
        )
    }

    private func execute(
        sourceURL: URL, edits: EditState, maximumDimension: Int, command: String,
        format: ExportFormat = .png, colorSpace: ExportColorSpace = .sRGB, quality: Double = 0.95
    ) async throws -> HelperExecutionResult {
        guard let runtime else {
            throw PhotoEngineError.unavailable(runtimeFailure)
        }
        guard quality.isFinite, (0...1).contains(quality), (0...Int(Int32.max)).contains(maximumDimension) else {
            throw PhotoEngineError.unsupported("Export quality or output dimensions are invalid.")
        }
        try runtime.validate()
        try Task.checkCancellation()
        let manager = FileManager.default
        let directory = cacheDirectory.appendingPathComponent("Requests/\(UUID().uuidString)")
        let log = directory.appendingPathComponent("helper.log")
        do {
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
                quality: max(1, Int((min(1, max(0, quality)) * 100).rounded()))
            )
            let request = directory.appendingPathComponent("request.json")
            let response = directory.appendingPathComponent("response.json")
            try JSONEncoder().encode(wire).write(to: request, options: .atomic)
            try await process.run(
                executable: runtime.executable,
                arguments: runtime.arguments(
                    command: command, request: request, response: response, directory: directory
                ),
                logURL: log
            )
            let result = try JSONDecoder().decode(HelperWireResponse.self, from: Data(contentsOf: response))
            try? manager.removeItem(at: source)
            return HelperExecutionResult(response: result, output: output, directory: directory)
        } catch {
            let message = helperMessage(error, logURL: log)
            try? manager.removeItem(at: directory)
            if Task.isCancelled { throw CancellationError() }
            throw PhotoEngineError.processing(String(message.suffix(2_000)))
        }
    }

    func query<Input: Encodable & Sendable, Output: Decodable & Sendable>(
        _ command: String, input: Input
    ) async throws -> Output {
        guard let runtime else { throw PhotoEngineError.unavailable(runtimeFailure) }
        try runtime.validate()
        let directory = cacheDirectory.appendingPathComponent("Queries/\(UUID().uuidString)")
        let manager = FileManager.default
        defer { try? manager.removeItem(at: directory) }
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
            return output
        } catch {
            let message = helperMessage(error, logURL: log)
            if Task.isCancelled { throw CancellationError() }
            throw PhotoEngineError.processing(String(message.suffix(2_000)))
        }
    }

    private func helperMessage(_ error: any Error, logURL: URL) -> String {
        let recorded = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        return recorded.isEmpty ? error.localizedDescription : recorded
    }
}

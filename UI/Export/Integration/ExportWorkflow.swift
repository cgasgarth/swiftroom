#if EXPORT_INTEGRATION
import Foundation

@main
@MainActor
struct ExportWorkflow {
    static func main() async throws {
        let manager = FileManager.default
        let parent = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let root = parent.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        let originals = root.appendingPathComponent("Inputs", isDirectory: true)
        let output = root.appendingPathComponent("Exports", isDirectory: true)
        try manager.createDirectory(at: originals, withIntermediateDirectories: true)
        try manager.createDirectory(at: output, withIntermediateDirectories: true)
        let source = originals.appendingPathComponent("Source.tiff")
        let other = originals.appendingPathComponent("Other.tif")
        try ExportImages.fixture(at: source)
        try manager.copyItem(at: source, to: other)
        let originalHash = try ExportImages.hash(source)
        let catalog = root.appendingPathComponent("Catalog.nativephotocatalog", isDirectory: true)
        let engine = NativePhotoEngineFactory.make(cacheDirectory: catalog.appendingPathComponent("Cache"))
        let store = try EditorStore(engine: engine, catalogURL: catalog)
        await store.importURLs([source, other])
        await store.waitForRender()
        guard store.documents.count == 2, let selected = store.selectedDocument else {
            throw ExportPresentationError.invalid("The real engine did not import the fixtures.")
        }
        let snapshot = selected.edits
        var exports = try await exportFormats(store: store, output: output)
        exports += try await exportSizing(store: store, output: output)
        try await replacementAndCancellation(store: store, output: output)
        try await conflictsAndOriginals(store: store, output: output, originals: [source, other])
        try await changedReplacement(store: store, output: output)
        try await frozenRequest(store: store, output: output)
        guard try ExportImages.hash(source) == originalHash, try ExportImages.hash(other) == originalHash,
              store.selectedDocument?.edits == snapshot else {
            throw ExportPresentationError.invalid("Export changed an original or the document edits.")
        }
        let evidence: [String: Any] = ["exports": exports, "noEnlargement": true,
            "replacementAndCancellation": true, "conflictsAndOriginals": true, "sourceHashesPreserved": true]
        try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("export-evidence.json"), options: .atomic)
        print("Export integration passed: formats, 3 distinct ICC profiles, dimensions, TIFF spellings, Unicode, "
            + "replacement, cancellation, conflicts and original aliases. Evidence: \(root.path)")
    }

    private static func exportFormats(store: EditorStore, output: URL) async throws -> [[String: String]] {
        var exports: [[String: String]] = []
        for format in ExportFormat.allCases {
            for profile in ExportColorSpace.allCases {
                let model = ExportPresentation(store: store, folderURL: output)
                model.format = format
                model.colorSpace = profile
                model.fileName = "Café 東京 \(profile.rawValue).\(format.fileExtension)"
                model.quality = 0.73
                model.resize = true
                model.maximumDimension = "120"
                model.beginExport()
                await model.waitForExport()
                let result = try requireResult(model)
                guard result.pixelWidth == 120, result.pixelHeight == 80 else {
                    throw ExportPresentationError.invalid("Proportional resizing changed the fixture dimensions.")
                }
                exports.append(try ExportImages.inspect(result, format: format, maximum: 120))
            }
        }
        guard Set(exports.prefix(3).compactMap { $0["iccSHA256"] }).count == 3 else {
            throw ExportPresentationError.invalid("The three requested profiles did not produce distinct ICC data.")
        }
        return exports
    }

    private static func exportSizing(store: EditorStore, output: URL) async throws -> [[String: String]] {
        var exports: [[String: String]] = []
        for spelling in ["tif", "tiff"] {
            let model = ExportPresentation(store: store, folderURL: output)
            model.format = .tiff
            model.fileName = "Full Size.\(spelling)"
            model.beginExport()
            await model.waitForExport()
            let result = try requireResult(model)
            guard result.pixelWidth == 480, result.pixelHeight == 320 else {
                throw ExportPresentationError.invalid("Full-size export dimensions were not preserved.")
            }
            exports.append(try ExportImages.inspect(result, format: .tiff, maximum: nil))
        }
        let larger = ExportPresentation(store: store, folderURL: output)
        larger.format = .jpeg
        larger.fileName = "No Enlargement.jpg"
        larger.resize = true
        larger.maximumDimension = "4096"
        larger.beginExport()
        await larger.waitForExport()
        let largeResult = try requireResult(larger)
        guard largeResult.pixelWidth == 480, largeResult.pixelHeight == 320 else {
            throw ExportPresentationError.invalid("The engine enlarged the fixture.")
        }
        return exports
    }

    private static func replacementAndCancellation(store: EditorStore, output: URL) async throws {
        let destination = output.appendingPathComponent("Replace.tiff")
        let sentinel = Data("disposable conflicting destination".utf8)
        try sentinel.write(to: destination)
        let model = ExportPresentation(store: store, folderURL: output)
        model.format = .tiff
        model.fileName = destination.lastPathComponent
        model.beginExport()
        guard model.pendingReplacement != nil, !model.isBusy, try Data(contentsOf: destination) == sentinel else {
            throw ExportPresentationError.invalid("A conflict started exporting before confirmation.")
        }
        model.dismissReplacement()
        guard try Data(contentsOf: destination) == sentinel else {
            throw ExportPresentationError.invalid("Cancelling confirmation changed the destination.")
        }
        model.beginExport()
        guard let request = model.pendingReplacement else {
            throw ExportPresentationError.invalid("Replacement confirmation was not restored.")
        }
        model.confirmReplacement(request)
        try await Task.sleep(for: .milliseconds(80))
        model.cancel()
        await model.waitForExport()
        guard case .cancelled = model.phase, try Data(contentsOf: destination) == sentinel else {
            throw ExportPresentationError.invalid("A cancelled export changed its destination.")
        }
        model.beginExport()
        guard let retry = model.pendingReplacement else {
            throw ExportPresentationError.invalid("Retry did not ask to replace the conflicting destination.")
        }
        model.confirmReplacement(retry)
        await model.waitForExport()
        _ = try ExportImages.inspect(requireResult(model), format: .tiff, maximum: nil)
        let fresh = ExportPresentation(store: store, folderURL: output)
        fresh.format = .jpeg
        fresh.fileName = "Cancelled Fresh.jpg"
        fresh.beginExport()
        try await Task.sleep(for: .milliseconds(80))
        fresh.cancel()
        await fresh.waitForExport()
        guard case .cancelled = fresh.phase,
              !FileManager.default.fileExists(atPath: output.appendingPathComponent(fresh.fileName).path) else {
            throw ExportPresentationError.invalid("A cancelled fresh export was published.")
        }
    }

    private static func conflictsAndOriginals(store: EditorStore, output: URL, originals: [URL]) async throws {
        let manager = FileManager.default
        let late = ExportPresentation(store: store, folderURL: output)
        late.format = .jpeg
        late.fileName = "Late Conflict.jpg"
        late.beginExport()
        try await Task.sleep(for: .milliseconds(80))
        let sentinel = Data("a new file appeared during rendering".utf8)
        let lateURL = output.appendingPathComponent(late.fileName)
        try sentinel.write(to: lateURL)
        await late.waitForExport()
        guard late.failure != nil, try Data(contentsOf: lateURL) == sentinel else {
            throw ExportPresentationError.invalid("Export overwrote a destination that appeared after validation.")
        }
        for original in originals {
            let sourceModel = ExportPresentation(store: store, folderURL: original.deletingLastPathComponent())
            sourceModel.format = .tiff
            sourceModel.fileName = original.lastPathComponent
            sourceModel.beginExport()
            guard sourceModel.failure != nil, sourceModel.pendingReplacement == nil else {
                throw ExportPresentationError.invalid("An original was offered for replacement.")
            }
            for alias in ["symlink", "hardlink"] {
                let aliasURL = output.appendingPathComponent("\(original.lastPathComponent)-\(alias).tiff")
                if alias == "symlink" {
                    try manager.createSymbolicLink(at: aliasURL, withDestinationURL: original)
                } else {
                    try manager.linkItem(at: original, to: aliasURL)
                }
                let model = ExportPresentation(store: store, folderURL: output)
                model.format = .tiff
                model.fileName = aliasURL.lastPathComponent
                model.beginExport()
                guard model.failure != nil, model.pendingReplacement == nil else {
                    throw ExportPresentationError.invalid("An original alias was offered for replacement.")
                }
            }
        }
        for document in store.documents {
            let copy = store.catalogURL.appendingPathComponent(document.relativeOriginalPath)
            let model = ExportPresentation(store: store, folderURL: copy.deletingLastPathComponent())
            model.format = .tiff
            model.fileName = copy.lastPathComponent
            model.beginExport()
            guard model.failure != nil, model.pendingReplacement == nil else {
                throw ExportPresentationError.invalid("A catalog original was offered for replacement.")
            }
        }
    }

    private static func requireResult(_ model: ExportPresentation) throws -> ExportResult {
        guard let result = model.result else {
            throw ExportPresentationError.invalid(model.failure ?? "Export did not complete.")
        }
        return result
    }

    private static func changedReplacement(store: EditorStore, output: URL) async throws {
        let destination = output.appendingPathComponent("Changed Replacement.tiff")
        try Data("initial disposable conflict".utf8).write(to: destination)
        let model = ExportPresentation(store: store, folderURL: output)
        model.format = .tiff
        model.fileName = destination.lastPathComponent
        model.beginExport()
        guard let request = model.pendingReplacement else {
            throw ExportPresentationError.invalid("Changed replacement did not request confirmation.")
        }
        model.confirmReplacement(request)
        try await Task.sleep(for: .milliseconds(80))
        let changed = Data("destination was changed after replacement confirmation".utf8)
        try changed.write(to: destination)
        await model.waitForExport()
        guard model.failure != nil, try Data(contentsOf: destination) == changed else {
            throw ExportPresentationError.invalid("Export replaced a changed destination using stale authorization.")
        }
    }

    private static func frozenRequest(store: EditorStore, output: URL) async throws {
        let model = ExportPresentation(store: store, folderURL: output)
        model.format = .png
        model.colorSpace = .sRGB
        model.resize = true
        model.maximumDimension = "120"
        model.fileName = "Frozen Request.png"
        let destination = output.appendingPathComponent(model.fileName)
        try Data("disposable frozen-request conflict".utf8).write(to: destination)
        model.beginExport()
        guard let request = model.pendingReplacement else {
            throw ExportPresentationError.invalid("The immutable export request was not captured.")
        }
        store.setExposure(1)
        model.confirmReplacement(request)
        await model.waitForExport()
        let result = try requireResult(model)
        let baseline = output.appendingPathComponent("Café 東京 sRGB.png")
        guard try ExportImages.pixels(result.destinationURL) == ExportImages.pixels(baseline),
              store.exposureEV == 1 else {
            throw ExportPresentationError.invalid("Export did not preserve its frozen edits or changed the document.")
        }
        store.restoreHistory(0)
        await store.waitForRender()
    }
}
#endif

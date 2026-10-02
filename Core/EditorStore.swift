import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

@MainActor
final class EditorStore: ObservableObject {
    @Published private(set) var documents: [PhotoDocument] = []
    @Published private(set) var selectedAssetID: UUID?
    @Published private(set) var preview: RenderedPhoto?
    @Published private(set) var cachedPreviews: [UUID: RenderedPhoto] = [:]
    @Published private(set) var editRevision: UInt64 = 0
    @Published private(set) var isRendering = false
    @Published private(set) var isImporting = false
    @Published private(set) var isExporting = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var statusMessage = "Ready to import"
    @Published private(set) var lastExport: ExportResult?
    @Published private(set) var catalogURL: URL
    @Published private(set) var hasUnsavedChanges = false
    @Published private(set) var library = LibraryCatalog()
    @Published var zoom: Double = 0
    @Published var isInspectorVisible = true
    @Published var isLibraryVisible = true
    @Published var exportFormat: ExportFormat = .jpeg
    @Published var exportColorSpace: ExportColorSpace = .sRGB
    @Published var exportQuality: Double = 0.95
    @Published var isExportSheetPresented = false

    let engine: any PhotoEngine
    var capabilities: EngineCapabilities { engine.capabilities }
    var selectedDocument: PhotoDocument? { documents.first { $0.id == selectedAssetID } }
    var canUndo: Bool { selectedDocument?.canUndo ?? false }
    var canRedo: Bool { selectedDocument?.canRedo ?? false }
    var history: [HistoryEntry] { selectedDocument?.history ?? [] }
    var currentEdits: EditState { selectedDocument?.edits ?? .original }
    var exposureEV: Double { currentEdits.exposureEV }
    var temperature: Double { currentEdits.temperature ?? 6500 }
    var tint: Double { currentEdits.tint }
    var catalogName: String { catalogURL.lastPathComponent.replacingOccurrences(of: ".nativephotocatalog", with: "") }
    var catalogID: UUID { catalog.id }
    var thumbnailURLs: [UUID: URL] { thumbnailService.urls }
    var thumbnailErrors: [UUID: String] { thumbnailService.errors }
    var thumbnailGeneration: UInt64 { thumbnailService.generation }

    private var repository: CatalogRepository
    private var catalog: PhotoCatalog
    private var renderTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var editGestureAssetID: UUID?
    private var editGestureLabel: String?
    private var previewMaximumDimension = 2560
    private var retiredPreviews: [URL: RenderedPhoto] = [:]
    private var previewCleanup: Task<Void, Never>?
    private var thumbnailChange: AnyCancellable?
    private lazy var thumbnailService: PhotoThumbnailService = {
        let service = PhotoThumbnailService(store: self)
        thumbnailChange = service.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        return service
    }()

    init(engine: any PhotoEngine, catalogURL: URL) throws {
        self.engine = engine
        self.catalogURL = catalogURL
        repository = CatalogRepository(rootURL: catalogURL)
        catalog = try repository.load()
        documents = catalog.documents
        library = (catalog.library ?? LibraryCatalog()).normalized(knownAssetIDs: Set(documents.map(\.id)))
        selectedAssetID = catalog.selectedAssetID.flatMap { id in
            documents.contains { $0.id == id } ? id : nil
        } ?? documents.first?.id
        statusMessage = documents.isEmpty ? "Ready to import" : "\(documents.count) photos"
    }

    func start() { requestRender(immediate: true) }

    func clearError() { errorMessage = nil }
    func reportError(_ message: String) { errorMessage = message; statusMessage = "Needs attention" }
    func requestThumbnail(_ assetID: UUID) async { await thumbnailService.request(assetID) }
    func retryThumbnail(_ assetID: UUID) { thumbnailService.retry(assetID) }
    func waitForThumbnails() async { await thumbnailService.waitUntilIdle() }
    func waitForPreviewCleanup() async { await previewCleanup?.value }

    func previewDidPresent(_ url: URL) {
        guard preview?.imageURL == url else { return }
        releaseRetiredPreviews()
    }

    func previewDidClear() {
        guard preview == nil else { return }
        releaseRetiredPreviews()
    }

    private func releaseRetiredPreviews() {
        let retainedURLs = Set(cachedPreviews.values.map(\.imageURL))
        let released = retiredPreviews.values.filter { !retainedURLs.contains($0.imageURL) }
        for photo in released { retiredPreviews[photo.imageURL] = nil }
        let previousCleanup = previewCleanup
        previewCleanup = Task { [engine] in
            await previousCleanup?.value
            for photo in released { await engine.release(photo) }
        }
    }
}

extension EditorStore {

    func importPhotos() {
        let panel = NSOpenPanel()
        panel.title = "Import Photos"
        panel.message = "Photos are copied into this swiftroom catalog."
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image, .rawImage]
        guard panel.runModal() == .OK else { return }
        Task { await importURLs(panel.urls) }
    }

    func importURLs(_ urls: [URL]) async {
        guard !isImporting else { return }
        endEditing()
        isImporting = true
        errorMessage = nil
        defer { isImporting = false }
        let importRepository = repository
        let importCatalogID = catalog.id
        let importCatalogURL = catalogURL
        var importedIDs: [UUID] = []
        for (offset, url) in urls.enumerated() {
            statusMessage = "Importing \(offset + 1) of \(urls.count)…"
            do {
                let id = UUID()
                let relative = try await Task.detached(priority: .userInitiated) {
                    try importRepository.copyOriginal(from: url, id: id)
                }.value
                let copiedURL = importCatalogURL.appendingPathComponent(relative)
                let prepared: PreparedPhoto
                do { prepared = try await engine.prepare(sourceURL: copiedURL, edits: .original) } catch {
                    try? FileManager.default.removeItem(at: copiedURL.deletingLastPathComponent())
                    throw error
                }
                guard catalog.id == importCatalogID, catalogURL == importCatalogURL else {
                    try? FileManager.default.removeItem(at: copiedURL.deletingLastPathComponent())
                    throw CatalogError.invalid("The catalog changed during import.")
                }
                let document = PhotoDocument(id: id, fileName: url.lastPathComponent,
                    originalSourcePath: url.path, relativeOriginalPath: relative,
                    metadata: prepared.metadata, edits: prepared.edits,
                    history: [HistoryEntry(label: "Original", edits: prepared.edits)],
                    historyIndex: 0, savedEdits: prepared.edits)
                documents.append(document)
                importedIDs.append(id)
                hasUnsavedChanges = true
            } catch {
                reportError("Could not import \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        if let first = importedIDs.first { selectAsset(first) }
        if errorMessage == nil { statusMessage = "Imported \(importedIDs.count) photos" }
        do { try saveCatalog() } catch { reportError(error.localizedDescription) }
    }

    func selectAsset(_ id: UUID) {
        guard documents.contains(where: { $0.id == id }) else { return }
        endEditing()
        guard selectedAssetID != id else { if preview == nil { requestRender(immediate: true) }; return }
        renderTask?.cancel()
        selectedAssetID = id
        editRevision &+= 1
        preview = cachedPreviews[id]
        previewMaximumDimension = 2560
        zoom = 0
        errorMessage = nil
        requestRender(immediate: true)
    }

    func selectNextPhoto(_ direction: Int) {
        guard !documents.isEmpty else { return }
        let index = documents.firstIndex { $0.id == selectedAssetID } ?? 0
        selectAsset(documents[max(0, min(documents.count - 1, index + direction))].id)
    }

    func beginEditing(_ label: String = "Adjust photo") {
        guard let id = selectedAssetID else { return }
        if editGestureAssetID != nil { endEditing() }
        editGestureAssetID = id
        editGestureLabel = label
    }

    func endEditing() {
        guard let id = editGestureAssetID, let index = documents.firstIndex(where: { $0.id == id }) else {
            editGestureAssetID = nil; editGestureLabel = nil; return
        }
        let previousHistory = documents[index].history
        documents[index].commit(documents[index].edits, label: editGestureLabel ?? "Adjust photo")
        if documents[index].history != previousHistory { editRevision &+= 1 }
        editGestureAssetID = nil
        editGestureLabel = nil
        refreshDirtyState()
    }

    func setExposure(_ value: Double) {
        guard capabilities.supportsExposure else { return }
        updateEdits(label: "Exposure") { $0.exposureEV = max(-18, min(18, value)) }
    }

    func setTemperature(_ value: Double) {
        guard capabilities.supportsWhiteBalance else { return }
        updateEdits(label: "White balance") { $0.temperature = max(2000, min(12000, value)) }
    }

    func setTint(_ value: Double) {
        guard capabilities.supportsWhiteBalance else { return }
        updateEdits(label: "Tint") { $0.tint = max(-100, min(100, value)) }
    }

    func useAsShotWhiteBalance() {
        updateEdits(label: "As-shot white balance") { $0.temperature = nil; $0.tint = 0 }
    }

    func setModuleState(_ module: ModuleState) {
        guard capabilities.supportsModuleEditing else { return }
        updateEdits(label: module.name ?? module.operation) { edits in
            if let index = edits.modules.firstIndex(where: { $0.id == module.id }) {
                edits.modules[index] = module
            } else {
                edits.modules.append(module)
            }
        }
    }

    func commitCurrentModule(
        assetID: UUID, catalogID: UUID, expectedEdits: EditState, module: ModuleState,
        values: [String: ModuleParameterValue], label: String
    ) async throws -> Bool {
        guard capabilities.supportsModuleEditing, self.catalogID == catalogID,
              selectedAssetID == assetID, currentEdits == expectedEdits,
              expectedEdits.modules.contains(where: { $0.id == module.id }) else { return false }
        guard let document = selectedDocument else { return false }
        let startingGeneration = generation
        let startingCatalogURL = self.catalogURL
        let source = try repository.sourceURL(for: document)
        var prepared = expectedEdits
        if expectedEdits.exposureEV != 0 || expectedEdits.temperature != nil || expectedEdits.tint != 0 {
            prepared = try await engine.prepare(sourceURL: source, edits: expectedEdits).edits
        }
        for index in prepared.modules.indices {
            if let existing = expectedEdits.modules.first(where: {
                $0.operation == prepared.modules[index].operation && $0.instance == prepared.modules[index].instance
            }) { prepared.modules[index].id = existing.id }
        }
        guard let index = prepared.modules.firstIndex(where: { $0.id == module.id }) else { return false }
        prepared.modules[index] = try await engine.updating(module: prepared.modules[index], values: values)
        prepared.modules[index].name = module.name
        prepared.modules[index].enabled = module.enabled
        try Task.checkCancellation()
        guard self.catalogID == catalogID, selectedAssetID == assetID, currentEdits == expectedEdits,
              generation == startingGeneration, self.catalogURL == startingCatalogURL else { return false }
        endEditing()
        updateEdits(label: label) { $0 = prepared }
        return true
    }

    func currentMaskState() async throws -> MaskState {
        guard let maskEngine = engine as? any MaskEditingEngine, let document = selectedDocument else {
            throw PhotoEngineError.unsupported("Choose a photo with an engine that supports mask editing.")
        }
        let startingCatalogID = catalogID
        let startingCatalogURL = catalogURL
        let startingGeneration = generation
        let startingRevision = editRevision
        let result = try await maskEngine.maskState(
            sourceURL: try repository.sourceURL(for: document), edits: document.edits)
        try Task.checkCancellation()
        guard catalogID == startingCatalogID, catalogURL == startingCatalogURL,
              selectedAssetID == document.id, currentEdits == document.edits,
              generation == startingGeneration, editRevision == startingRevision else { throw CancellationError() }
        return result
    }

    func commitCurrentMasks(
        assetID: UUID, catalogID: UUID, expectedEdits: EditState, expectedRevision: UInt64,
        edit: MaskEdit, label: String
    ) async throws -> Bool {
        guard let maskEngine = engine as? any MaskEditingEngine, self.catalogID == catalogID,
              selectedAssetID == assetID, currentEdits == expectedEdits, editRevision == expectedRevision,
              let document = selectedDocument else { return false }
        let startingGeneration = generation
        let startingCatalogURL = self.catalogURL
        let prepared = try await maskEngine.applyingMasks(
            sourceURL: try repository.sourceURL(for: document), edits: expectedEdits, edit: edit)
        try Task.checkCancellation()
        guard self.catalogID == catalogID, self.catalogURL == startingCatalogURL,
              selectedAssetID == assetID, currentEdits == expectedEdits,
              generation == startingGeneration, editRevision == expectedRevision else { return false }
        var acceptedEdits = prepared.edits
        for index in acceptedEdits.modules.indices {
            if let existing = expectedEdits.modules.first(where: {
                $0.operation == acceptedEdits.modules[index].operation
                    && $0.instance == acceptedEdits.modules[index].instance
            }) { acceptedEdits.modules[index].id = existing.id }
        }
        endEditing()
        updateEdits(label: label) { $0 = acceptedEdits }
        return true
    }

    func resetEdits() {
        endEditing()
        updateEdits(label: "Reset adjustments") { $0 = .original }
    }

    func undo() {
        endEditing()
        guard let index = selectedIndex, documents[index].canUndo else { return }
        documents[index].undo()
        editRevision &+= 1
        refreshDirtyState()
        requestRender(immediate: true)
    }

    func redo() {
        endEditing()
        guard let index = selectedIndex, documents[index].canRedo else { return }
        documents[index].redo()
        editRevision &+= 1
        refreshDirtyState()
        requestRender(immediate: true)
    }

    func restoreHistory(_ index: Int) {
        endEditing()
        guard let selectedIndex else { return }
        documents[selectedIndex].restoreHistory(at: index)
        editRevision &+= 1
        refreshDirtyState()
        requestRender(immediate: true)
    }

    func setRating(_ rating: Int) {
        guard let index = selectedIndex else { return }
        documents[index].rating = max(0, min(5, rating))
        hasUnsavedChanges = true
    }

    func toggleRejected() {
        guard let index = selectedIndex else { return }
        documents[index].isRejected.toggle()
        hasUnsavedChanges = true
    }

    func updateLibrary(_ value: LibraryCatalog) {
        library = value.normalized(knownAssetIDs: Set(documents.map(\.id)))
        refreshDirtyState()
    }

    func setRatings(_ rating: Int, assetIDs: Set<UUID>) {
        for index in documents.indices where assetIDs.contains(documents[index].id) {
            documents[index].rating = max(0, min(5, rating))
        }
        refreshDirtyState()
    }

    func setRejected(_ rejected: Bool, assetIDs: Set<UUID>) {
        for index in documents.indices where assetIDs.contains(documents[index].id) {
            documents[index].isRejected = rejected
        }
        refreshDirtyState()
    }

    func clearAssetSelection() {
        endEditing()
        renderTask?.cancel()
        generation &+= 1
        editRevision &+= 1
        selectedAssetID = nil
        preview = nil
        isRendering = false
    }
}

extension EditorStore {

    func save() {
        do { try saveCatalog() } catch { reportError("Could not save catalog: \(error.localizedDescription)") }
    }

    func saveCatalog() throws {
        endEditing()
        var savedDocuments = documents
        for index in savedDocuments.indices { savedDocuments[index].savedEdits = savedDocuments[index].edits }
        var updatedCatalog = catalog
        updatedCatalog.documents = savedDocuments
        updatedCatalog.selectedAssetID = selectedAssetID
        updatedCatalog.library = library
        try repository.save(updatedCatalog)
        catalog = updatedCatalog
        documents = savedDocuments
        hasUnsavedChanges = false
        statusMessage = "Catalog saved"
    }

    func openCatalogPanel() {
        guard !isImporting else { return }
        let panel = NSOpenPanel()
        panel.title = "Open swiftroom Catalog"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try openCatalog(at: url) } catch { reportError(error.localizedDescription) }
    }

    func openCatalog(at url: URL) throws {
        guard !isImporting else {
            throw CatalogError.invalid("Wait for photo import to finish before opening a catalog.")
        }
        if hasUnsavedChanges { try saveCatalog() }
        let nextRepository = CatalogRepository(rootURL: url)
        let nextCatalog = try nextRepository.load()
        renderTask?.cancel()
        thumbnailService.reset()
        for photo in cachedPreviews.values { retiredPreviews[photo.imageURL] = photo }
        cachedPreviews.removeAll()
        repository = nextRepository
        catalog = nextCatalog
        catalogURL = url
        editRevision &+= 1
        documents = nextCatalog.documents
        library = (nextCatalog.library ?? LibraryCatalog()).normalized(knownAssetIDs: Set(documents.map(\.id)))
        selectedAssetID = nextCatalog.selectedAssetID.flatMap { id in
            documents.contains { $0.id == id } ? id : nil
        } ?? documents.first?.id
        preview = nil
        previewMaximumDimension = 2560
        zoom = 0
        hasUnsavedChanges = false
        errorMessage = nil
        requestRender(immediate: true)
    }

    func exportPhoto() {
        guard selectedDocument != nil, !isExporting else { return }
        isExportSheetPresented = true
    }

    func makeExportRequest(
        destination: URL, format: ExportFormat, colorSpace: ExportColorSpace,
        quality: Double, maximumDimension: Int?, overwriteAuthorization: ExportOverwriteAuthorization? = nil
    ) throws -> ExportRequest {
        endEditing()
        guard let document = selectedDocument else { throw PhotoEngineError.unsupported("Choose a photo to export.") }
        guard capabilities.supportsFullResolutionExport || maximumDimension != nil else {
            throw PhotoEngineError.unsupported("This engine does not support full-resolution export.")
        }
        let sources = try documents.flatMap { document in
            [try repository.sourceURL(for: document), URL(fileURLWithPath: document.originalSourcePath)]
        }
        let request = ExportRequest(
            assetID: document.id, sourceURL: try repository.sourceURL(for: document), edits: document.edits,
            destinationURL: destination, format: format, colorSpace: colorSpace, quality: quality,
            maximumDimension: maximumDimension, protectedSourceURLs: sources,
            protectedDirectories: [catalogURL.appendingPathComponent("Originals")],
            overwriteAuthorization: overwriteAuthorization)
        try ExportProtection.validateOriginals(request)
        return request
    }

    func export(_ request: ExportRequest) async throws -> ExportResult {
        guard !isExporting else { throw PhotoEngineError.processing("An export is already in progress.") }
        try ExportProtection.validate(request)
        isExporting = true
        defer { isExporting = false }
        statusMessage = "Exporting photo…"
        do {
            let result = try await engine.export(request)
            lastExport = result
            statusMessage = "Exported \(result.destinationURL.lastPathComponent)"
            return result
        } catch is CancellationError {
            statusMessage = "Export cancelled"
            throw CancellationError()
        } catch {
            statusMessage = "Export failed"
            throw error
        }
    }

    func export(to destination: URL, maximumDimension: Int? = nil) async {
        do {
            let request = try makeExportRequest(destination: destination, format: exportFormat,
                colorSpace: exportColorSpace, quality: exportQuality, maximumDimension: maximumDimension)
            _ = try await export(request)
        } catch { reportError("Export failed: \(error.localizedDescription)") }
    }

    func retryRender() { errorMessage = nil; requestRender(immediate: true) }
    func zoomToFit() { zoom = 0 }
    func zoomToActualSize() {
        zoom = 1
        renderSelectedAtFullResolution()
    }
    func renderSelectedAtFullResolution() {
        guard capabilities.supportsFullResolutionExport, let document = selectedDocument else { return }
        let dimension = max(document.metadata.pixelWidth, document.metadata.pixelHeight)
        previewMaximumDimension = dimension > 0 ? dimension : 0
        requestRender(immediate: true)
    }
    func zoomIn() { zoom = min(8, zoom == 0 ? 1 : zoom * 1.25) }
    func zoomOut() { zoom = zoom <= 0.25 ? 0 : zoom / 1.25 }

    func waitForRender() async { await renderTask?.value }

    private var selectedIndex: Int? { documents.firstIndex { $0.id == selectedAssetID } }

    private func updateEdits(label: String, mutation: (inout EditState) -> Void) {
        guard let index = selectedIndex else { return }
        var edits = documents[index].edits
        mutation(&edits)
        guard edits != documents[index].edits else { return }
        editRevision &+= 1
        if editGestureAssetID == selectedAssetID {
            documents[index].edits = edits
        } else {
            documents[index].commit(edits, label: label)
        }
        refreshDirtyState()
        requestRender(immediate: false)
    }

    private func refreshDirtyState() {
        hasUnsavedChanges = documents.contains(where: \.isDirty) || documents != catalog.documents
            || library != (catalog.library ?? LibraryCatalog())
    }

    private func requestRender(immediate: Bool) {
        renderTask?.cancel()
        generation &+= 1
        guard let document = selectedDocument else { isRendering = false; preview = nil; return }
        do {
            let request = RenderRequest(assetID: document.id, generation: generation,
                sourceURL: try repository.sourceURL(for: document), edits: document.edits,
                maximumDimension: previewMaximumDimension)
            isRendering = true
            statusMessage = "Developing \(document.fileName)…"
            renderTask = Task { [weak self, engine] in
                do {
                    if !immediate { try await Task.sleep(for: .milliseconds(180)) }
                    try Task.checkCancellation()
                    let result = try await engine.render(request)
                    guard !Task.isCancelled, let self, self.selectedAssetID == result.assetID,
                          self.generation == result.generation else {
                        await engine.release(result)
                        return
                    }
                    self.preview = result
                    if let previous = self.cachedPreviews.updateValue(result, forKey: result.assetID) {
                        self.retiredPreviews[previous.imageURL] = previous
                    }
                    self.isRendering = false
                    self.statusMessage = "\(result.pixelWidth) × \(result.pixelHeight) · \(result.colorSpaceName)"
                } catch is CancellationError { } catch {
                    guard let self, self.selectedAssetID == request.assetID,
                          self.generation == request.generation else { return }
                    self.isRendering = false
                    self.reportError("Could not develop \(document.fileName): \(error.localizedDescription)")
                }
            }
        } catch { isRendering = false; reportError(error.localizedDescription) }
    }
}

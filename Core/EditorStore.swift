import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

@MainActor
final class EditorStore: ObservableObject {
    @Published private(set) var documents: [PhotoDocument] = []
    @Published private(set) var selectedAssetID: UUID?
    @Published private(set) var preview: RenderedPhoto?
    @Published private(set) var isRendering = false
    @Published private(set) var isImporting = false
    @Published private(set) var isExporting = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var statusMessage = "Ready to import"
    @Published private(set) var lastExport: ExportResult?
    @Published private(set) var catalogURL: URL
    @Published private(set) var hasUnsavedChanges = false
    @Published var zoom: Double = 0
    @Published var isInspectorVisible = true
    @Published var isLibraryVisible = true
    @Published var exportFormat: ExportFormat = .jpeg
    @Published var exportColorSpace: ExportColorSpace = .sRGB
    @Published var exportQuality: Double = 0.95

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

    private var repository: CatalogRepository
    private var catalog: PhotoCatalog
    private var renderTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var editGestureAssetID: UUID?
    private var editGestureLabel: String?
    private var previewMaximumDimension = 2560

    init(engine: any PhotoEngine, catalogURL: URL) throws {
        self.engine = engine
        self.catalogURL = catalogURL
        repository = CatalogRepository(rootURL: catalogURL)
        catalog = try repository.load()
        documents = catalog.documents
        selectedAssetID = catalog.selectedAssetID.flatMap { id in
            documents.contains { $0.id == id } ? id : nil
        } ?? documents.first?.id
        statusMessage = documents.isEmpty ? "Ready to import" : "\(documents.count) photos"
    }

    func start() { requestRender(immediate: true) }

    func clearError() { errorMessage = nil }
    func reportError(_ message: String) { errorMessage = message; statusMessage = "Needs attention" }
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
        var importedIDs: [UUID] = []
        for (offset, url) in urls.enumerated() {
            statusMessage = "Importing \(offset + 1) of \(urls.count)…"
            do {
                let id = UUID()
                let currentRepository = repository
                let relative = try await Task.detached(priority: .userInitiated) {
                    try currentRepository.copyOriginal(from: url, id: id)
                }.value
                let copiedURL = catalogURL.appendingPathComponent(relative)
                let prepared: PreparedPhoto
                do { prepared = try await engine.prepare(sourceURL: copiedURL, edits: .original) } catch {
                    try? FileManager.default.removeItem(at: copiedURL.deletingLastPathComponent())
                    throw error
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
        preview = nil
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
        documents[index].commit(documents[index].edits, label: editGestureLabel ?? "Adjust photo")
        editGestureAssetID = nil
        editGestureLabel = nil
        refreshDirtyState()
    }

    func setExposure(_ value: Double) {
        guard capabilities.supportsExposure else { return }
        updateEdits(label: "Exposure") { $0.exposureEV = max(-6, min(6, value)) }
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

    func resetEdits() {
        endEditing()
        updateEdits(label: "Reset adjustments") { $0 = .original }
    }

    func undo() {
        endEditing()
        guard let index = selectedIndex, documents[index].canUndo else { return }
        documents[index].undo()
        refreshDirtyState()
        requestRender(immediate: true)
    }

    func redo() {
        endEditing()
        guard let index = selectedIndex, documents[index].canRedo else { return }
        documents[index].redo()
        refreshDirtyState()
        requestRender(immediate: true)
    }

    func restoreHistory(_ index: Int) {
        endEditing()
        guard let selectedIndex else { return }
        documents[selectedIndex].restoreHistory(at: index)
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
        try repository.save(updatedCatalog)
        catalog = updatedCatalog
        documents = savedDocuments
        hasUnsavedChanges = false
        statusMessage = "Catalog saved"
    }

    func openCatalogPanel() {
        let panel = NSOpenPanel()
        panel.title = "Open swiftroom Catalog"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try openCatalog(at: url) } catch { reportError(error.localizedDescription) }
    }

    func openCatalog(at url: URL) throws {
        if hasUnsavedChanges { try saveCatalog() }
        let nextRepository = CatalogRepository(rootURL: url)
        let nextCatalog = try nextRepository.load()
        renderTask?.cancel()
        repository = nextRepository
        catalog = nextCatalog
        catalogURL = url
        documents = nextCatalog.documents
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
        guard let document = selectedDocument, !isExporting else { return }
        let panel = NSSavePanel()
        panel.title = "Export Photo"
        let baseName = URL(fileURLWithPath: document.fileName).deletingPathExtension().lastPathComponent
        panel.nameFieldStringValue = baseName + "." + exportFormat.fileExtension
        panel.allowedContentTypes = [UTType(filenameExtension: exportFormat.fileExtension) ?? .image]
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        Task { await export(to: destination) }
    }

    func export(to destination: URL, maximumDimension: Int? = nil) async {
        guard let document = selectedDocument, !isExporting else { return }
        endEditing()
        guard capabilities.supportsFullResolutionExport || maximumDimension != nil else {
            reportError("This engine does not support full-resolution export."); return
        }
        do {
            let sourceURL = try repository.sourceURL(for: document)
            let originalsPath = repository.rootURL.standardizedFileURL.path + "/Originals/"
            guard destination.standardizedFileURL != sourceURL.standardizedFileURL,
                  !destination.standardizedFileURL.path.hasPrefix(originalsPath) else {
                throw CatalogError.invalid("Choose an export location outside the catalog originals.")
            }
            let request = ExportRequest(assetID: document.id, sourceURL: sourceURL,
                edits: document.edits, destinationURL: destination, format: exportFormat,
                colorSpace: exportColorSpace, quality: exportQuality, maximumDimension: maximumDimension)
            isExporting = true
            defer { isExporting = false }
            statusMessage = "Exporting \(document.fileName)…"
            lastExport = try await engine.export(request)
            statusMessage = "Exported \(destination.lastPathComponent)"
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
                    try Task.checkCancellation()
                    guard let self, self.selectedAssetID == result.assetID,
                          self.generation == result.generation else { return }
                    self.preview = result
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

import AppKit
import Combine
import Foundation

enum ExportPhase {
    case ready, exporting, cancelling, cancelled
    case failed(String)
    case completed(ExportResult)
}

@MainActor
final class ExportPresentation: ObservableObject {
    @Published var fileName: String
    @Published var folderURL: URL
    @Published var format: ExportFormat
    @Published var colorSpace: ExportColorSpace
    @Published var quality: Double
    @Published var resize = false
    @Published var maximumDimension = "2048"
    @Published private(set) var phase = ExportPhase.ready
    @Published private(set) var pendingReplacement: ExportRequest?

    let sourceName: String
    let sourceMetadata: PhotoMetadata
    let store: EditorStore
    private let assetID: UUID?
    private let catalogURL: URL
    private var exportTask: Task<Void, Never>?

    init(store: EditorStore, folderURL: URL? = nil) {
        self.store = store
        let document = store.selectedDocument
        assetID = document?.id
        catalogURL = store.catalogURL
        sourceName = document?.fileName ?? "Photo"
        sourceMetadata = document?.metadata ?? .unknown
        format = store.exportFormat
        colorSpace = store.exportColorSpace
        quality = store.exportQuality
        fileName = URL(fileURLWithPath: sourceName).deletingPathExtension().lastPathComponent
            + "." + store.exportFormat.fileExtension
        self.folderURL = folderURL
            ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
    }

    var isBusy: Bool {
        switch phase {
        case .exporting, .cancelling: return true
        case .ready, .cancelled, .failed, .completed: return false
        }
    }

    var isCancelling: Bool {
        if case .cancelling = phase { return true }
        return false
    }

    var result: ExportResult? {
        if case .completed(let value) = phase { return value }
        return nil
    }

    var failure: String? {
        if case .failed(let message) = phase { return message }
        return nil
    }

    var formats: [ExportFormat] { store.capabilities.supportedExportFormats }
    var profiles: [ExportColorSpace] { store.capabilities.supportedExportColorSpaces }

    var validationMessage: String? {
        do {
            _ = try destination()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    var sizeDescription: String {
        if resize {
            return "Fits within \(maximumDimension) × \(maximumDimension) pixels; preserves proportions."
        }
        return "Full processed dimensions, including crop and rotation."
    }

    func changeFormat(_ value: ExportFormat) {
        fileName = ExportDestination.name(fileName, changingTo: value)
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose Export Folder"
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = folderURL
        guard panel.runModal() == .OK, let url = panel.url else { return }
        folderURL = url
    }

    func beginExport() {
        guard !isBusy, pendingReplacement == nil else { return }
        do {
            let destination = try destination()
            let request = try store.makeExportRequest(
                destination: destination, format: format, colorSpace: colorSpace,
                quality: quality, maximumDimension: resize ? Int(maximumDimension) : nil)
            store.exportFormat = format
            store.exportColorSpace = colorSpace
            store.exportQuality = quality
            if FileManager.default.fileExists(atPath: destination.path) {
                pendingReplacement = request
            } else {
                start(request)
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func dismissReplacement() { pendingReplacement = nil }

    func confirmReplacement(_ pending: ExportRequest) {
        guard !isBusy else { return }
        var request = pending
        pendingReplacement = nil
        do {
            request.overwriteAuthorization = try ExportOverwriteAuthorization.capture(
                destination: request.destinationURL)
            start(request)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func cancel() {
        guard isBusy, !isCancelling else { return }
        phase = .cancelling
        exportTask?.cancel()
    }

    func waitForExport() async { await exportTask?.value }

    private func destination() throws -> URL {
        guard assetID != nil, store.selectedAssetID == assetID, store.catalogURL == catalogURL else {
            throw ExportPresentationError.invalid("The selected photo changed. Close this sheet and export it again.")
        }
        guard store.capabilities.supportsFullResolutionExport else {
            throw ExportPresentationError.invalid("The photo engine is unavailable for export.")
        }
        guard formats.contains(format), profiles.contains(colorSpace) else {
            throw ExportPresentationError.invalid("Choose a format and profile supported by the photo engine.")
        }
        guard quality.isFinite, (0.01...1).contains(quality) else {
            throw ExportPresentationError.invalid("Choose a JPEG quality between 1 and 100 percent.")
        }
        if resize {
            guard let dimension = Int(maximumDimension), (1...65535).contains(dimension) else {
                throw ExportPresentationError.invalid("Enter a maximum dimension from 1 to 65,535 pixels.")
            }
        }
        return try ExportDestination.validate(folder: folderURL, fileName: fileName, format: format)
    }

    private func start(_ request: ExportRequest) {
        phase = .exporting
        exportTask = Task { [weak self, store] in
            do {
                let result = try await store.export(request)
                self?.phase = .completed(result)
            } catch is CancellationError {
                self?.phase = .cancelled
            } catch {
                self?.phase = .failed(error.localizedDescription)
            }
            self?.exportTask = nil
        }
    }
}

import Combine
import Foundation

struct PhotoThumbnailRevision: Equatable {
    var catalogID: UUID
    var catalogURL: URL
    var assetID: UUID
    var edits: EditState
    var generation: UInt64
}

@MainActor
final class PhotoThumbnailService: ObservableObject {
    @Published private(set) var urls: [UUID: URL] = [:]
    @Published private(set) var errors: [UUID: String] = [:]
    @Published private(set) var generation: UInt64 = 0
    private weak var store: EditorStore?
    private let engine: any PhotoEngine
    private let frameLimit: Int
    private let queueLimit = 24
    private var consumers: [UUID: Consumer] = [:]
    private var frames: [Frame] = []
    private var queue: [Snapshot] = []
    private var worker: Task<Void, Never>?
    private var workerID: UUID?
    private var active: Snapshot?
    private var activeRender: Task<RenderedPhoto, any Error>?
    private var sequence: UInt64 = 0

    init(store: EditorStore, maximumRetainedFrames: Int = 40) {
        self.store = store
        engine = store.engine
        frameLimit = max(1, min(128, maximumRetainedFrames))
    }

    func request(_ assetID: UUID) async {
        guard let snapshot = snapshot(for: assetID) else { return }
        let token = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(); return }
                consumers[token] = Consumer(snapshot: snapshot, continuation: continuation)
                removeMissingFrames()
                if let index = frames.firstIndex(where: { $0.snapshot == snapshot }),
                   FileManager.default.fileExists(atPath: frames[index].photo.imageURL.path) {
                    sequence &+= 1
                    frames[index].access = sequence
                    urls[assetID] = frames[index].photo.imageURL
                } else {
                    urls[assetID] = nil
                    errors[assetID] = nil
                    replenishQueue()
                    startWorker()
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.removeConsumer(token) }
        }
    }

    func retry(_ assetID: UUID) {
        errors[assetID] = nil
        replenishQueue()
        startWorker()
    }

    func reset() {
        generation &+= 1
        worker?.cancel()
        activeRender?.cancel()
        queue.removeAll()
        let previousConsumers = consumers.values
        consumers.removeAll()
        for consumer in previousConsumers { consumer.continuation.resume() }
        let previousFrames = frames
        frames.removeAll()
        urls.removeAll()
        errors.removeAll()
        for frame in previousFrames { release(frame.photo) }
    }

    func waitUntilIdle() async { await worker?.value }

    private struct Snapshot: Equatable {
        let catalogID: UUID
        let catalogURL: URL
        let assetID: UUID
        let edits: EditState
        let sourceURL: URL
    }

    private struct Consumer {
        let snapshot: Snapshot
        let continuation: CheckedContinuation<Void, Never>
    }

    private struct Frame {
        let snapshot: Snapshot
        let photo: RenderedPhoto
        var access: UInt64
    }

    private func snapshot(for assetID: UUID) -> Snapshot? {
        guard let store, let document = store.documents.first(where: { $0.id == assetID }),
              let sourceURL = try? CatalogRepository(rootURL: store.catalogURL).sourceURL(for: document) else {
            return nil
        }
        return Snapshot(catalogID: store.catalogID, catalogURL: store.catalogURL, assetID: assetID,
            edits: document.edits, sourceURL: sourceURL)
    }

    private func isCurrent(_ snapshot: Snapshot) -> Bool {
        self.snapshot(for: snapshot.assetID) == snapshot
    }

    private func isConsumed(_ snapshot: Snapshot) -> Bool {
        consumers.values.contains { $0.snapshot == snapshot }
    }

    private func removeConsumer(_ token: UUID) {
        guard let removed = consumers.removeValue(forKey: token) else { return }
        removed.continuation.resume()
        if active == removed.snapshot, !isConsumed(removed.snapshot) { activeRender?.cancel() }
        queue.removeAll { !isConsumed($0) || !isCurrent($0) }
        trimFrames(reserving: 0)
        replenishQueue()
        startWorker()
    }

    private func replenishQueue() {
        for consumer in consumers.values {
            let snapshot = consumer.snapshot
            guard queue.count < queueLimit else { return }
            guard isCurrent(snapshot), errors[snapshot.assetID] == nil, active != snapshot,
                  !queue.contains(snapshot), !frames.contains(where: { $0.snapshot == snapshot }) else { continue }
            queue.append(snapshot)
        }
    }

    private func release(_ photo: RenderedPhoto) {
        Task { [engine] in await engine.release(photo) }
    }

    private func removeMissingFrames() {
        let missing = frames.filter { !FileManager.default.fileExists(atPath: $0.photo.imageURL.path) }
        for frame in missing {
            frames.removeAll { $0.photo.imageURL == frame.photo.imageURL }
            if urls[frame.snapshot.assetID] == frame.photo.imageURL { urls[frame.snapshot.assetID] = nil }
            release(frame.photo)
        }
    }

    private func trimFrames(reserving count: Int) {
        let removable = frames.filter { !isConsumed($0.snapshot) }.sorted { $0.access < $1.access }
        for frame in removable {
            guard !isCurrent(frame.snapshot) || frames.count > frameLimit - count else { continue }
            frames.removeAll { $0.photo.imageURL == frame.photo.imageURL }
            if urls[frame.snapshot.assetID] == frame.photo.imageURL { urls[frame.snapshot.assetID] = nil }
            release(frame.photo)
        }
    }
}

extension PhotoThumbnailService {
    private func startWorker() {
        guard worker == nil, !queue.isEmpty else { return }
        let identifier = UUID()
        workerID = identifier
        worker = Task(priority: .utility) { [weak self] in
            await self?.drainQueue(identifier: identifier)
        }
    }

    private func drainQueue(identifier: UUID) async {
        defer {
            if workerID == identifier {
                worker = nil
                workerID = nil
                active = nil
                activeRender = nil
                replenishQueue()
                startWorker()
            }
        }
        while !Task.isCancelled, let store, !queue.isEmpty {
            if store.isRendering || store.isImporting || store.isExporting {
                do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
                continue
            }
            trimFrames(reserving: 1)
            if frames.count >= frameLimit {
                do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
                continue
            }
            let next = queue.removeFirst()
            guard isConsumed(next), isCurrent(next) else { continue }
            await render(next, expectedGeneration: generation)
            replenishQueue()
        }
    }

    private func render(_ snapshot: Snapshot, expectedGeneration: UInt64) async {
        active = snapshot
        sequence &+= 1
        let request = RenderRequest(assetID: snapshot.assetID, generation: sequence,
            sourceURL: snapshot.sourceURL, edits: snapshot.edits, maximumDimension: 240)
        let render = Task { [engine] in try await engine.render(request) }
        activeRender = render
        defer { active = nil; activeRender = nil }
        do {
            let photo = try await render.value
            guard !Task.isCancelled, !render.isCancelled, generation == expectedGeneration,
                  isCurrent(snapshot), isConsumed(snapshot) else {
                await engine.release(photo)
                return
            }
            guard photo.assetID == snapshot.assetID, photo.generation == request.generation,
                  photo.pixelWidth > 0, photo.pixelHeight > 0,
                  max(photo.pixelWidth, photo.pixelHeight) <= 240 else {
                await engine.release(photo)
                errors[snapshot.assetID] = "The engine returned an invalid thumbnail."
                return
            }
            sequence &+= 1
            frames.append(Frame(snapshot: snapshot, photo: photo, access: sequence))
            urls[snapshot.assetID] = photo.imageURL
            errors[snapshot.assetID] = nil
            trimFrames(reserving: 0)
        } catch is CancellationError {
        } catch {
            if generation == expectedGeneration, isCurrent(snapshot), isConsumed(snapshot) {
                errors[snapshot.assetID] = error.localizedDescription
            }
        }
    }
}

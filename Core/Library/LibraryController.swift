import Combine
import Foundation

@MainActor
final class LibraryController: ObservableObject {
    let store: EditorStore
    @Published var query = LibraryQuery() {
        didSet { reconcileSelection() }
    }
    @Published private(set) var selectedIDs: Set<UUID> = []
    private var catalogURL: URL
    private var lastFocusedID: UUID?
    private var rangeAnchorID: UUID?

    init(store: EditorStore) {
        self.store = store
        catalogURL = store.catalogURL
        lastFocusedID = store.selectedAssetID
        if let id = store.selectedAssetID { selectedIDs = [id] }
    }

    var visibleDocuments: [PhotoDocument] { query.documents(in: store.documents, library: store.library) }
    var activeCollection: PhotoCollection? {
        guard case .collection(let id) = query.scope else { return nil }
        return store.library.collections.first { $0.id == id }
    }
    var selectionIsFavorite: Bool {
        !selectedIDs.isEmpty && selectedIDs.isSubset(of: store.library.favorites)
    }
    var selectionIsRejected: Bool {
        !selectedIDs.isEmpty && store.documents.filter { selectedIDs.contains($0.id) }.allSatisfy(\.isRejected)
    }

    func synchronize() {
        if catalogURL != store.catalogURL {
            catalogURL = store.catalogURL
            selectedIDs = store.selectedAssetID.map { [$0] } ?? []
            lastFocusedID = store.selectedAssetID
            rangeAnchorID = store.selectedAssetID
            query = LibraryQuery()
        }
        if case .collection(let id) = query.scope, !store.library.collections.contains(where: { $0.id == id }) {
            query.scope = .all
        }
        let focusChanged = store.selectedAssetID != lastFocusedID
        if focusChanged, let id = store.selectedAssetID, visibleDocuments.contains(where: { $0.id == id }) {
            if !selectedIDs.contains(id) { selectedIDs = [id] }
            rangeAnchorID = id
        } else if focusChanged, store.selectedAssetID == nil {
            selectedIDs = []
        }
        reconcileSelection(selectFirstIfEmpty: !selectedIDs.isEmpty || store.selectedAssetID != nil)
    }

    func select(_ ids: Set<UUID>, preferredID: UUID? = nil) {
        let visibleIDs = Set(visibleDocuments.map(\.id))
        let valid = ids.intersection(visibleIDs)
        let added = valid.subtracting(selectedIDs)
        let preferred = preferredID ?? visibleDocuments.first { added.contains($0.id) }?.id
        selectedIDs = valid
        if let preferred { rangeAnchorID = preferred }
        reconcileSelection(preferredID: preferred, selectFirstIfEmpty: false)
    }

    func selectAll() {
        select(Set(visibleDocuments.map(\.id)), preferredID: store.selectedAssetID)
    }

    func clearSelection() {
        selectedIDs = []
        rangeAnchorID = nil
        store.clearAssetSelection()
        lastFocusedID = nil
    }

    func moveSelection(_ direction: Int, extending: Bool = false) {
        let documents = visibleDocuments
        guard !documents.isEmpty else { return }
        let currentIndex = documents.firstIndex { $0.id == store.selectedAssetID }
        let nextIndex: Int
        if let currentIndex {
            nextIndex = max(0, min(documents.count - 1, currentIndex + direction))
        } else {
            nextIndex = direction < 0 ? documents.count - 1 : 0
        }
        let nextID = documents[nextIndex].id
        if extending, let anchorIndex = documents.firstIndex(where: { $0.id == rangeAnchorID }) {
            selectedIDs = Set(documents[min(anchorIndex, nextIndex)...max(anchorIndex, nextIndex)].map(\.id))
            reconcileSelection(preferredID: nextID, selectFirstIfEmpty: false)
        } else {
            select([nextID], preferredID: nextID)
            rangeAnchorID = nextID
        }
    }

    func setRating(_ rating: Int, ids: Set<UUID>? = nil) {
        store.setRatings(rating, assetIDs: ids ?? selectedIDs)
        reconcileSelection()
    }

    func toggleFavorites(ids: Set<UUID>? = nil) {
        let targets = validIDs(ids ?? selectedIDs)
        guard !targets.isEmpty else { return }
        var library = store.library
        if targets.isSubset(of: library.favorites) {
            library.favorites.subtract(targets)
        } else {
            library.favorites.formUnion(targets)
        }
        store.updateLibrary(library)
        reconcileSelection()
    }

    func toggleRejected(ids: Set<UUID>? = nil) {
        let targets = validIDs(ids ?? selectedIDs)
        guard !targets.isEmpty else { return }
        let rejected = store.documents.filter { targets.contains($0.id) }.allSatisfy(\.isRejected)
        store.setRejected(!rejected, assetIDs: targets)
        reconcileSelection()
    }

    @discardableResult
    func createCollection(name: String, addingSelection: Bool) -> UUID? {
        guard store.library.collectionNameAvailable(name) else { return nil }
        let collection = PhotoCollection(name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            assetIDs: addingSelection ? validIDs(selectedIDs) : [])
        var library = store.library
        library.collections.append(collection)
        store.updateLibrary(library)
        query.scope = .collection(collection.id)
        return collection.id
    }

    @discardableResult
    func renameCollection(_ id: UUID, name: String) -> Bool {
        guard store.library.collectionNameAvailable(name, excluding: id),
              let index = store.library.collections.firstIndex(where: { $0.id == id }) else { return false }
        var library = store.library
        library.collections[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        store.updateLibrary(library)
        return true
    }

    func addToCollection(_ id: UUID, ids: Set<UUID>? = nil) {
        guard let index = store.library.collections.firstIndex(where: { $0.id == id }) else { return }
        var library = store.library
        library.collections[index].assetIDs.formUnion(validIDs(ids ?? selectedIDs))
        store.updateLibrary(library)
        reconcileSelection()
    }

    func removeFromCollection(_ id: UUID, ids: Set<UUID>? = nil) {
        guard let index = store.library.collections.firstIndex(where: { $0.id == id }) else { return }
        var library = store.library
        library.collections[index].assetIDs.subtract(ids ?? selectedIDs)
        store.updateLibrary(library)
        reconcileSelection()
    }

    func deleteCollection(_ id: UUID) {
        var library = store.library
        library.collections.removeAll { $0.id == id }
        store.updateLibrary(library)
        if query.scope == .collection(id) { query.scope = .all }
        reconcileSelection()
    }

    func resetFilters() { query = LibraryQuery() }

    private func validIDs(_ ids: Set<UUID>) -> Set<UUID> {
        ids.intersection(Set(store.documents.map(\.id)))
    }

    private func reconcileSelection(preferredID: UUID? = nil, selectFirstIfEmpty: Bool = true) {
        let visible = visibleDocuments
        selectedIDs.formIntersection(Set(visible.map(\.id)))
        let focus: UUID?
        if let preferredID, selectedIDs.contains(preferredID) {
            focus = preferredID
        } else if let current = store.selectedAssetID, selectedIDs.contains(current) {
            focus = current
        } else if let first = visible.first(where: { selectedIDs.contains($0.id) }) {
            focus = first.id
        } else if selectFirstIfEmpty, let first = visible.first {
            focus = first.id
            selectedIDs = [first.id]
        } else {
            focus = nil
        }
        if let focus {
            if store.selectedAssetID != focus { store.selectAsset(focus) }
        } else if store.selectedAssetID != nil {
            store.clearAssetSelection()
        }
        lastFocusedID = store.selectedAssetID
    }
}

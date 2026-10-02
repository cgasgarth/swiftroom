import Foundation

struct PhotoCollection: Codable, Equatable, Identifiable, Sendable {
    var id: UUID = UUID()
    var name: String
    var assetIDs: Set<UUID> = []
}

struct LibraryCatalog: Codable, Equatable, Sendable {
    var favorites: Set<UUID> = []
    var collections: [PhotoCollection] = []

    func normalized(knownAssetIDs: Set<UUID>) -> LibraryCatalog {
        var result = self
        result.favorites.formIntersection(knownAssetIDs)
        var identifiers: Set<UUID> = []
        result.collections = collections.compactMap { collection in
            guard identifiers.insert(collection.id).inserted else { return nil }
            var updated = collection
            updated.name = collection.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !updated.name.isEmpty else { return nil }
            updated.assetIDs.formIntersection(knownAssetIDs)
            return updated
        }
        return result
    }

    func collectionNameAvailable(_ name: String, excluding id: UUID? = nil) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && !collections.contains {
            $0.id != id && $0.name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame
        }
    }
}

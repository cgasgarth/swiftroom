import Foundation

enum LibraryScope: Hashable, Sendable {
    case all, favorites, rejected, collection(UUID)
}

enum LibraryRatingFilter: Int, CaseIterable, Sendable {
    case any = -1, unrated = 0, one, two, three, four, five

    var title: String {
        switch self {
        case .any: return "Any rating"
        case .unrated: return "Unrated"
        case .five: return "5 stars"
        default: return "\(rawValue)+ stars"
        }
    }

    func includes(_ rating: Int) -> Bool {
        switch self {
        case .any: return true
        case .unrated: return rating == 0
        default: return rating >= rawValue
        }
    }
}

enum LibrarySort: String, CaseIterable, Sendable {
    case fileName = "Name"
    case rating = "Rating"
    case captureDate = "Capture date"
    case importedAt = "Import date"
}

struct LibraryQuery: Equatable, Sendable {
    var search = ""
    var scope: LibraryScope = .all
    var rating: LibraryRatingFilter = .any
    var sort: LibrarySort = .fileName
    var descending = false
    var hidesRejected = false

    func documents(in documents: [PhotoDocument], library: LibraryCatalog) -> [PhotoDocument] {
        let tokens = search.split(whereSeparator: \.isWhitespace).map(String.init)
        let collectionIDs: Set<UUID>
        if case .collection(let id) = scope {
            collectionIDs = library.collections.first { $0.id == id }?.assetIDs ?? []
        } else {
            collectionIDs = []
        }
        return documents.filter { document in
            guard rating.includes(document.rating), !hidesRejected || !document.isRejected else { return false }
            switch scope {
            case .all: break
            case .favorites: guard library.favorites.contains(document.id) else { return false }
            case .rejected: guard document.isRejected else { return false }
            case .collection: guard collectionIDs.contains(document.id) else { return false }
            }
            let searchable = [document.fileName, document.metadata.camera ?? "", document.metadata.lens ?? ""]
                .joined(separator: " ")
            return tokens.allSatisfy { searchable.localizedStandardContains($0) }
        }.sorted { left, right in
            let order = compare(left, right)
            return descending ? order == .orderedDescending : order == .orderedAscending
        }
    }

    private func compare(_ left: PhotoDocument, _ right: PhotoDocument) -> ComparisonResult {
        let order: ComparisonResult
        switch sort {
        case .fileName: order = left.fileName.localizedStandardCompare(right.fileName)
        case .rating: order = compareValues(left.rating, right.rating)
        case .captureDate:
            order = compareValues(left.metadata.captureDate ?? .distantPast, right.metadata.captureDate ?? .distantPast)
        case .importedAt: order = compareValues(left.importedAt, right.importedAt)
        }
        guard order == .orderedSame else { return order }
        let nameOrder = left.fileName.localizedStandardCompare(right.fileName)
        return nameOrder == .orderedSame ? left.id.uuidString.compare(right.id.uuidString) : nameOrder
    }

    private func compareValues<Value: Comparable>(_ left: Value, _ right: Value) -> ComparisonResult {
        if left < right { return .orderedAscending }
        return left > right ? .orderedDescending : .orderedSame
    }
}

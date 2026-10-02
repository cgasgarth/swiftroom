import SwiftUI

@MainActor
struct NativeLibraryRow: View {
    let document: PhotoDocument
    let isFavorite: Bool
    let imageURL: URL?

    var body: some View {
        HStack(spacing: 8) {
            NativeLibraryThumbnail(imageURL: imageURL).frame(width: 42, height: 38)
            VStack(alignment: .leading, spacing: 3) {
                Text(document.fileName).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 4) {
                    if document.rating > 0 {
                        Label("\(document.rating)", systemImage: "star.fill")
                    }
                    if isFavorite { Image(systemName: "heart.fill").accessibilityLabel("Favorite") }
                    if document.isRejected { Image(systemName: "xmark.circle").accessibilityLabel("Rejected") }
                    if document.isDirty { Image(systemName: "pencil").accessibilityLabel("Unsaved adjustments") }
                    Text(document.metadata.camera ?? document.fileName.components(separatedBy: ".").last?.uppercased()
                        ?? "Photo").lineLimit(1).truncationMode(.tail)
                }.font(.caption).foregroundStyle(.secondary)
            }.font(.callout)
        }
        .padding(.vertical, 3)
        .help(document.fileName)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(document.fileName)
        .accessibilityValue("\(document.rating) stars\(isFavorite ? ", favorite" : "")"
            + "\(document.isRejected ? ", rejected" : "")\(document.isDirty ? ", unsaved adjustments" : "")")
        .accessibilityIdentifier("library.photo.\(document.id.uuidString)")
    }
}

@MainActor
struct NativeLibraryThumbnail: View {
    let imageURL: URL?

    var body: some View {
        Group {
            if let imageURL {
                AsyncImage(url: imageURL) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFit()
                    } else {
                        pending
                    }
                }
            } else {
                pending
            }
        }.background(Color(nsColor: .controlBackgroundColor))
            .accessibilityHidden(true)
    }

    private var pending: some View {
        Image(systemName: "photo").foregroundStyle(.tertiary).help("Preview available after developing this photo")
    }
}

@MainActor
struct NativeLibraryActions: View {
    @ObservedObject var model: LibraryController
    let targets: Set<UUID>

    var body: some View {
        Menu("Rating") {
            ForEach(0...5, id: \.self) { rating in
                Button(rating == 0 ? "Unrated" : "\(rating) stars") { model.setRating(rating, ids: targets) }
            }
        }
        Button(targets.isSubset(of: model.store.library.favorites) ? "Remove Favorite" : "Mark Favorite") {
            model.toggleFavorites(ids: targets)
        }
        Button(allRejected ? "Unreject" : "Reject") { model.toggleRejected(ids: targets) }
        if !model.store.library.collections.isEmpty {
            Menu("Add to Collection") {
                ForEach(model.store.library.collections) { collection in
                    Button(collection.name) { model.addToCollection(collection.id, ids: targets) }
                        .disabled(targets.isSubset(of: collection.assetIDs))
                }
            }
        }
        if let collection = model.activeCollection {
            Button("Remove from \(collection.name)") { model.removeFromCollection(collection.id, ids: targets) }
        }
    }

    private var allRejected: Bool {
        !targets.isEmpty && model.store.documents.filter { targets.contains($0.id) }.allSatisfy(\.isRejected)
    }
}

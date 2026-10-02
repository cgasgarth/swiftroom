import SwiftUI

@MainActor
struct NativeLibraryBrowser: View {
    @ObservedObject var store: EditorStore
    @ObservedObject var model: LibraryController
    @Environment(\.dismiss) private var dismiss
    let previewURLs: [UUID: URL]

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Library Browser").font(.title2)
                Spacer()
                Text("\(model.visibleDocuments.count) of \(store.documents.count) photos").foregroundStyle(.secondary)
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            HStack {
                TextField("Search photos", text: $model.query.search).textFieldStyle(.roundedBorder)
                Picker("Sort", selection: $model.query.sort) {
                    ForEach(LibrarySort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.frame(width: 200)
                Button { model.query.descending.toggle() } label: {
                    Image(systemName: model.query.descending ? "arrow.down" : "arrow.up")
                }.help("Reverse sort order").accessibilityLabel("Reverse sort order")
            }
            HStack {
                Picker("Show", selection: Binding(get: { model.query.scope }, set: model.setScope)) {
                    Text("All Photos").tag(LibraryScope.all)
                    Text("Favorites").tag(LibraryScope.favorites)
                    Text("Rejected").tag(LibraryScope.rejected)
                    ForEach(store.library.collections) { collection in
                        Text(collection.name).tag(LibraryScope.collection(collection.id))
                    }
                }
                Picker("Rating", selection: $model.query.rating) {
                    ForEach(LibraryRatingFilter.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Toggle("Hide rejected", isOn: $model.query.hidesRejected)
                    .disabled(model.query.scope == .rejected)
                Button("Reset Filters", action: model.resetFilters)
            }.controlSize(.small)
            Table(model.visibleDocuments, selection: Binding(get: { model.selectedIDs }, set: { model.select($0) })) {
                TableColumn("Photo") { document in
                    NativeLibraryRow(document: document, isFavorite: store.library.favorites.contains(document.id),
                        imageURL: NativeLibraryRow.imageURL(for: document.id, store: store, previewURLs: previewURLs),
                        thumbnailError: store.thumbnailErrors[document.id])
                        .task(id: PhotoThumbnailRevision(catalogID: store.catalogID, catalogURL: store.catalogURL,
                            assetID: document.id, edits: document.edits, generation: store.thumbnailGeneration)) {
                            await store.requestThumbnail(document.id)
                        }
                }.width(min: 200, ideal: 300)
                TableColumn("Rating") { document in Text("\(document.rating)") }.width(60)
                TableColumn("Camera") { document in Text(document.metadata.camera ?? "—") }
                TableColumn("Captured") { document in
                    if let date = document.metadata.captureDate { Text(date, style: .date) } else { Text("—") }
                }
                TableColumn("Dimensions") { document in
                    Text("\(document.metadata.pixelWidth) × \(document.metadata.pixelHeight)")
                }
            }
            .accessibilityIdentifier("library.table")
            .modifier(NativeLibraryKeyboard(model: model))
            .contextMenu(forSelectionType: UUID.self) { ids in
                if !ids.isEmpty { NativeLibraryActions(model: model, targets: ids) }
                ForEach(thumbnailFailures(in: ids)) { document in
                    Button("Retry Thumbnail: \(document.fileName)") { store.retryThumbnail(document.id) }
                }
            } primaryAction: { ids in
                model.select(ids)
                dismiss()
            }
            HStack {
                Text("\(model.selectedIDs.count) selected").foregroundStyle(.secondary)
                Spacer()
                Button("Select All Shown", action: model.selectAll).disabled(model.visibleDocuments.isEmpty)
                Menu("Selection Actions") { NativeLibraryActions(model: model, targets: model.selectedIDs) }
                    .disabled(model.selectedIDs.isEmpty)
                Button("Edit Photo") { dismiss() }.disabled(store.selectedDocument == nil)
                    .keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(minWidth: 760, idealWidth: 900, minHeight: 480, idealHeight: 620)
    }

    private func thumbnailFailures(in ids: Set<UUID>) -> [PhotoDocument] {
        model.visibleDocuments.filter { ids.contains($0.id) && store.thumbnailErrors[$0.id] != nil }
    }
}

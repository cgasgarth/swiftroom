import SwiftUI

@MainActor
struct NativeLibraryView: View {
    @ObservedObject var store: EditorStore
    @StateObject private var model: LibraryController
    @State private var collectionDraft: LibraryCollectionDraft?
    @State private var showsBrowser = false
    @State private var showsDeleteConfirmation = false
    let previewURLs: [UUID: URL]

    init(store: EditorStore, previewURLs: [UUID: URL] = [:]) {
        self.store = store
        self.previewURLs = previewURLs
        _model = StateObject(wrappedValue: LibraryController(store: store))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            filters.padding(.horizontal, 12).padding(.bottom, 12)
            Divider()
            photoList
            Divider()
            footer
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: store.documents) { _, _ in model.synchronize() }
        .onChange(of: store.library) { _, _ in model.synchronize() }
        .onChange(of: store.selectedAssetID) { _, _ in model.synchronize() }
        .onChange(of: store.catalogURL) { _, _ in model.synchronize() }
        .onAppear { model.synchronize() }
        .sheet(item: $collectionDraft) { draft in LibraryCollectionEditor(model: model, draft: draft) }
        .sheet(isPresented: $showsBrowser) {
            NativeLibraryBrowser(store: store, model: model, previewURLs: previewURLs)
        }
        .confirmationDialog("Delete this collection?", isPresented: $showsDeleteConfirmation) {
            if let collection = model.activeCollection {
                Button("Delete \(collection.name)", role: .destructive) { model.deleteCollection(collection.id) }
            }
        } message: {
            Text("Photos and adjustments stay in the catalog.")
        }
    }

    private var header: some View {
        HStack {
            Text("Library").font(.headline)
            Spacer()
            Button { showsBrowser = true } label: { Image(systemName: "rectangle.expand.vertical") }
                .buttonStyle(.borderless).help("Open library browser")
                .accessibilityLabel("Open library browser").accessibilityIdentifier("library.browser")
            Menu {
                Button("New Collection…") { collectionDraft = LibraryCollectionDraft() }
                if let collection = model.activeCollection {
                    Button("Rename Collection…") {
                        collectionDraft = LibraryCollectionDraft(collection: collection)
                    }
                    Button("Delete Collection…", role: .destructive) { showsDeleteConfirmation = true }
                }
                Divider()
                Button("Select All Shown", action: model.selectAll)
                    .disabled(model.visibleDocuments.isEmpty)
                Button("Clear Selection", action: model.clearSelection).disabled(model.selectedIDs.isEmpty)
                Button("Reset Filters", action: model.resetFilters)
            } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton).fixedSize()
            .help("Library options").accessibilityLabel("Library options")
            .accessibilityIdentifier("library.options")
        }.padding(.horizontal, 14).padding(.top, 16).padding(.bottom, 12)
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Search photos", text: $model.query.search)
                .textFieldStyle(.roundedBorder).accessibilityIdentifier("library.search")
            Picker("Show", selection: Binding(get: { model.query.scope }, set: model.setScope)) {
                Text("All Photos").tag(LibraryScope.all)
                Text("Favorites").tag(LibraryScope.favorites)
                Text("Rejected").tag(LibraryScope.rejected)
                ForEach(store.library.collections) { collection in
                    Text("\(collection.name) (\(collection.assetIDs.count))")
                        .tag(LibraryScope.collection(collection.id))
                }
            }.accessibilityIdentifier("library.scope")
            Picker("Rating", selection: $model.query.rating) {
                ForEach(LibraryRatingFilter.allCases, id: \.self) { Text($0.title).tag($0) }
            }.accessibilityIdentifier("library.ratingFilter")
            HStack(spacing: 6) {
                Picker("Sort", selection: $model.query.sort) {
                    ForEach(LibrarySort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.accessibilityIdentifier("library.sort")
                Button { model.query.descending.toggle() } label: {
                    Image(systemName: model.query.descending ? "arrow.down" : "arrow.up")
                }
                .buttonStyle(.borderless).help(model.query.descending ? "Sort ascending" : "Sort descending")
                .accessibilityLabel("Sort direction")
                .accessibilityValue(model.query.descending ? "Descending" : "Ascending")
            }
            Toggle("Hide rejected", isOn: $model.query.hidesRejected)
                .disabled(model.query.scope == .rejected).accessibilityIdentifier("library.hideRejected")
        }.controlSize(.small)
    }

    private var photoList: some View {
        List(selection: Binding(get: { model.selectedIDs }, set: { model.select($0) })) {
            ForEach(model.visibleDocuments) { document in
                NativeLibraryRow(document: document, isFavorite: store.library.favorites.contains(document.id),
                    imageURL: NativeLibraryRow.imageURL(for: document.id, store: store, previewURLs: previewURLs),
                    thumbnailError: store.thumbnailErrors[document.id])
                    .tag(document.id)
                    .task(id: PhotoThumbnailRevision(catalogID: store.catalogID, catalogURL: store.catalogURL,
                        assetID: document.id, edits: document.edits, generation: store.thumbnailGeneration)) {
                        await store.requestThumbnail(document.id)
                    }
                    .contextMenu {
                        NativeLibraryActions(model: model,
                            targets: model.selectedIDs.contains(document.id) ? model.selectedIDs : [document.id])
                        if store.thumbnailErrors[document.id] != nil {
                            Button("Retry Thumbnail") { store.retryThumbnail(document.id) }
                        }
                    }
            }
        }
        .listStyle(.sidebar).accessibilityIdentifier("library.photos")
        .modifier(NativeLibraryKeyboard(model: model))
        .overlay {
            if model.visibleDocuments.isEmpty {
                VStack(spacing: 8) {
                    Text(store.documents.isEmpty ? "No photos yet" : "No matching photos")
                        .font(.callout).foregroundStyle(.secondary)
                    if !store.documents.isEmpty {
                        Button("Reset Filters", action: model.resetFilters).controlSize(.small)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(model.visibleDocuments.count) of \(store.documents.count) photos").foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Menu { NativeLibraryActions(model: model, targets: model.selectedIDs) } label: {
                    Image(systemName: "star.circle")
                }
                .menuStyle(.borderlessButton).fixedSize().disabled(model.selectedIDs.isEmpty)
                .help("Rate and organize selection").accessibilityLabel("Selection actions")
                .accessibilityIdentifier("library.selectionActions")
            }
            if !model.selectedIDs.isEmpty { Text("\(model.selectedIDs.count) selected").foregroundStyle(.secondary) }
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(store.catalogName).lineLimit(1).truncationMode(.middle)
                    Text(store.hasUnsavedChanges ? "Unsaved changes" : "Saved catalog").foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Button(action: store.save) { Image(systemName: "square.and.arrow.down") }
                    .buttonStyle(.borderless).disabled(!store.hasUnsavedChanges)
                    .help("Save catalog").accessibilityLabel("Save catalog")
                Button(action: store.openCatalogPanel) { Image(systemName: "folder") }
                    .buttonStyle(.borderless).help("Open catalog").accessibilityLabel("Open catalog")
                    .disabled(store.isImporting)
            }
        }.font(.caption).padding(12).accessibilityIdentifier("library.summary")
    }

}

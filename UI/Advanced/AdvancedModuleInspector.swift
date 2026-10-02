import SwiftUI

@MainActor
struct AdvancedModuleInspector: View {
    @ObservedObject var store: EditorStore
    var operations: Set<String>?
    @State private var descriptors: [ProcessingModule] = []
    @State private var search = ""
    @State private var errorMessage: String?

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 20) {
            TextField("Search adjustments", text: $search)
                .textFieldStyle(.roundedBorder).accessibilityIdentifier("advanced.search")
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.secondary)
            }
            if retainedModules.isEmpty {
                Text(search.isEmpty ? "No retained adjustments are available for this photo."
                    : "No adjustments match this search.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(retainedModules) { module in
                AdvancedModuleGroup(store: store, module: module, descriptors: descriptors)
                Divider()
            }
            availableOperations
            DisclosureGroup("Editing Support") {
                Text("Unit labels are shown where verified; other values use darktable’s stored scale. "
                    + "Finer stored values are preserved until edited. Use Masks for supported geometry and blending. "
                    + "Curve editors, parametric masks, mask drawing and new instances are unavailable.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 6)
            }
        }
        .accessibilityIdentifier("advanced.inspector")
        .task(id: store.catalogID) {
            do {
                let loaded = try await store.engine.modules()
                try Task.checkCancellation()
                descriptors = loaded
                errorMessage = nil
            } catch is CancellationError {} catch { errorMessage = error.localizedDescription }
        }
    }

    private var retainedModules: [ModuleState] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.currentEdits.modules.filter { module in
            (operations == nil || operations?.contains(module.operation) == true)
                && (query.isEmpty || module.operation.localizedStandardContains(query)
                || descriptors.first(where: { $0.operation == module.operation })?.title
                    .localizedStandardContains(query) == true
                || module.name?.localizedStandardContains(query) == true)
        }.sorted { $0.order < $1.order }
    }

    private var availableOperations: some View {
        DisclosureGroup("Other Available Adjustments") {
            VStack(alignment: .leading, spacing: 8) {
                Text("These adjustments are not used in this photo. Adding them is not yet available.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(descriptors.filter { descriptor in
                    (operations == nil || operations?.contains(descriptor.operation) == true)
                        && !store.currentEdits.modules.contains { $0.operation == descriptor.operation }
                        && (search.isEmpty || descriptor.title.localizedStandardContains(search)
                            || descriptor.operation.localizedStandardContains(search))
                }) { descriptor in
                    Text(descriptor.title.prefix(1).uppercased() + descriptor.title.dropFirst()).font(.callout)
                }
            }.padding(.top, 6)
        }
    }
}

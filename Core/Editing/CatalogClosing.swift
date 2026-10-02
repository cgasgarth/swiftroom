import Foundation

enum CatalogCloseChoice: Sendable {
    case save, discard, cancel
}

extension EditorStore {
    func prepareToClose(_ choice: CatalogCloseChoice) -> Bool {
        guard !isUpdatingEdits else {
            reportError("Wait for the current adjustment to finish before closing swiftroom.")
            return false
        }
        endEditing()
        guard !isImporting, !isExporting else {
            reportError("Wait for photo import or export to finish before closing swiftroom.")
            return false
        }
        switch choice {
        case .cancel: return false
        case .discard: return true
        case .save:
            do {
                if hasUnsavedChanges { try saveCatalog() }
                return true
            } catch {
                reportError("Could not save catalog: \(error.localizedDescription)")
                return false
            }
        }
    }
}

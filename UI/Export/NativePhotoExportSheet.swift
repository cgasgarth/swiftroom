import AppKit
import SwiftUI

@MainActor
struct NativePhotoExportSheet: View {
    @StateObject private var model: ExportPresentation
    @Environment(\.dismiss) private var dismiss

    init(store: EditorStore) {
        _model = StateObject(wrappedValue: ExportPresentation(store: store))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let result = model.result {
                completion(result)
            } else {
                settings
            }
            Divider()
            footer
        }
        .frame(width: 540)
        .background(Color(nsColor: .windowBackgroundColor))
        .interactiveDismissDisabled(model.isBusy)
        .onChange(of: model.format) { _, value in model.changeFormat(value) }
        .confirmationDialog("Replace this file?", isPresented: replacementBinding,
                            titleVisibility: .visible, presenting: model.pendingReplacement) { request in
            Button("Replace", role: .destructive) { model.confirmReplacement(request) }
                .accessibilityIdentifier("export.replace")
            Button("Cancel", role: .cancel, action: model.dismissReplacement)
        } message: { request in
            Text("\(request.destinationURL.lastPathComponent) already exists. "
                + "Its contents will be replaced after the new export is ready.")
        }
        .accessibilityIdentifier("export.sheet")
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "square.and.arrow.up")
                .font(.title2).foregroundStyle(.secondary).frame(width: 34)
            VStack(alignment: .leading, spacing: 4) {
                Text("Export Photo").font(.title2.weight(.semibold))
                Text(model.sourceName).font(.subheadline).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
        }
        .padding(24)
    }

    private var settings: some View {
        Form {
            Section("Destination") {
                TextField("Filename", text: $model.fileName)
                    .accessibilityIdentifier("export.filename")
                LabeledContent("Folder") {
                    HStack {
                        Text(model.folderURL.path).lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(.secondary).help(model.folderURL.path)
                        Button("Choose…", action: model.chooseFolder)
                            .accessibilityIdentifier("export.folder")
                    }
                }
            }
            Section("Image") {
                Picker("Format", selection: $model.format) {
                    ForEach(model.formats, id: \.self) { Text($0.displayName).tag($0) }
                }
                .accessibilityIdentifier("export.format")
                Picker("Color profile", selection: $model.colorSpace) {
                    ForEach(model.profiles, id: \.self) { Text($0.displayName).tag($0) }
                }
                .accessibilityIdentifier("export.profile")
                if model.format == .jpeg {
                    LabeledContent("Quality") {
                        HStack(spacing: 12) {
                            Slider(value: $model.quality, in: 0.01...1, step: 0.01)
                                .accessibilityLabel("JPEG quality").accessibilityIdentifier("export.quality")
                            Text(model.quality, format: .percent.precision(.fractionLength(0)))
                                .monospacedDigit().frame(width: 42, alignment: .trailing)
                        }
                    }
                }
                LabeledContent("Bit depth", value: model.format == .jpeg ? "8 bits per channel" : "16 bits per channel")
                LabeledContent("Rendering intent", value: "Perceptual")
            }
            Section("Dimensions") {
                if model.sourceMetadata.pixelWidth > 0, model.sourceMetadata.pixelHeight > 0 {
                    LabeledContent("Source", value:
                        "\(model.sourceMetadata.pixelWidth) × \(model.sourceMetadata.pixelHeight) pixels")
                }
                Toggle("Limit maximum dimension", isOn: $model.resize)
                    .accessibilityIdentifier("export.resize")
                if model.resize {
                    TextField("Maximum width or height", text: $model.maximumDimension)
                        .accessibilityIdentifier("export.dimension")
                }
                Text(model.sizeDescription).font(.caption).foregroundStyle(.secondary)
                Text("Images are never enlarged. The finished export reports its actual dimensions.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(height: 340)
        .disabled(model.isBusy)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 14) {
            status
            HStack {
                if model.result == nil {
                    Button(model.isBusy ? "Cancel Export" : "Cancel") {
                        if model.isBusy { model.cancel() } else { dismiss() }
                    }
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.isCancelling)
                    .accessibilityIdentifier("export.cancel")
                }
                Spacer()
                if let result = model.result {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([result.destinationURL])
                    }
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                } else {
                    Button(model.failure == nil ? "Export" : "Retry Export", action: model.beginExport)
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.isBusy || model.validationMessage != nil)
                        .accessibilityIdentifier("export.submit")
                }
            }
        }
        .padding(24)
    }

    @ViewBuilder
    private var status: some View {
        if model.isBusy {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(model.isCancelling ? "Stopping export…" : "Rendering and writing export…")
            }
            .accessibilityIdentifier("export.progress")
        } else if let failure = model.failure {
            ScrollView {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("export.error")
            }
            .frame(height: 56)
        } else if let validation = model.validationMessage, model.result == nil {
            Label(validation, systemImage: "exclamationmark.circle")
                .foregroundStyle(.secondary).accessibilityIdentifier("export.validation")
        } else if case .cancelled = model.phase {
            Label("Export cancelled. Your settings are ready to try again.", systemImage: "xmark.circle")
                .foregroundStyle(.secondary).accessibilityIdentifier("export.cancelled")
        }
    }

    private func completion(_ result: ExportResult) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Photo exported", systemImage: "checkmark.circle.fill")
                .font(.title3.weight(.semibold)).foregroundStyle(.green)
            Text(result.destinationURL.lastPathComponent).font(.headline).textSelection(.enabled)
            LabeledContent("Dimensions", value: "\(result.pixelWidth) × \(result.pixelHeight) pixels")
            LabeledContent("Embedded profile", value: result.colorSpaceName)
            Text(result.destinationURL.deletingLastPathComponent().path)
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
        .padding(24).frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("export.complete")
    }

    private var replacementBinding: Binding<Bool> {
        Binding(get: { model.pendingReplacement != nil }, set: { if !$0 { model.dismissReplacement() } })
    }
}

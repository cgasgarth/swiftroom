import SwiftUI

@MainActor
struct MaskBlendFields: View {
    @ObservedObject var model: MaskInspectorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Module Blending").font(.headline)
            Picker("Module", selection: Binding(get: { model.selectedModuleID }, set: model.chooseModule)) {
                Text("Choose a module").tag(Optional<UUID>.none)
                ForEach(model.modules) { module in
                    Text(model.moduleTitle(module)).tag(Optional(module.id))
                }
            }.disabled(model.isApplying).accessibilityIdentifier("masks.blend.module")
            if let blend = model.selectedBlend {
                blendFields(blend)
            } else {
                Text("This module has no supported blend seed. Its existing data is retained.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func blendFields(_ blend: BlendState) -> some View {
        if model.canEditBlend {
            VStack(alignment: .leading, spacing: 12) {
                MaskNumericControl(
                    title: "Opacity (%)", fieldID: "blend.opacity", range: 0...100,
                    value: $model.draftOpacity, onValidity: model.setValidity)
                Picker("Blend mode", selection: $model.draftMode) {
                    ForEach(blend.supportedModes, id: \.self) { mode in
                        Text(String(describing: mode).capitalized).tag(mode.rawValue)
                    }
                    if !blend.supportedModes.contains(where: { $0.rawValue == blend.mode & 0xFF }) {
                        Text("Retained mode \(blend.mode & 0xFF)").tag(blend.mode & 0xFF)
                    }
                }.accessibilityIdentifier("masks.blend.mode")
                Toggle("Reverse blending", isOn: $model.draftReversed)
                    .accessibilityIdentifier("masks.blend.reversed")
                if blend.supportsDrawnMasks {
                    assignmentFields(blend)
                } else {
                    Text("This module does not support drawn mask assignment.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if blend.maskMode.contains(.parametric) || blend.maskMode.contains(.raster) {
                    Text("Parametric and raster settings are retained. Native controls are unavailable.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(
                            horizontal: false, vertical: true)
                }
            }.id(model.draftRevision)
        } else {
            Text(
                "Blend version \(blend.version) is read-only. Opacity \(blend.opacity.formatted())%, "
                    + "mode \(blend.mode), mask \(blend.maskID). Its original bytes are retained."
            )
            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
        }
    }

    private func assignmentFields(_ blend: BlendState) -> some View {
        Picker("Drawn mask group", selection: $model.draftGroupID) {
            Text("No drawn mask").tag(Int32(0))
            ForEach(model.groups) { group in Text(group.name).tag(group.id) }
            if blend.maskMode.contains(.drawn), blend.maskID != 0,
                !model.groups.contains(where: { $0.id == blend.maskID }) {
                Text("Retained group \(blend.maskID)").tag(blend.maskID)
            }
        }.accessibilityIdentifier("masks.blend.group")
    }
}

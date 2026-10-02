import SwiftUI

@MainActor
struct AdvancedModuleFields: View {
    let schema: ModuleSchema
    let values: [String: ModuleParameterValue]
    var onSet: (String, ModuleParameterValue) -> Void
    var onValidity: (String, Bool) -> Void
    var onCommit: () -> Void = {}
    var onEditingChanged: (Bool) -> Void = { _ in }
    var onSliderSet: ((String, ModuleParameterValue) -> Void)?

    private var presentation: AdvancedFieldPresentation {
        AdvancedFieldPresentation(schema: schema, values: values)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(presentation.fields) { field in
                if let value = values[field.name] {
                    parameter(field, value: value)
                } else {
                    readOnly(field, value: "Value unavailable")
                }
            }
            if presentation.automatic == true {
                Text("Automatic metering requires a supported 16-bit RAW. Manual settings are retained.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            metadata
        }
    }

    @ViewBuilder
    private func parameter(_ field: ModuleParameterField, value: ModuleParameterValue) -> some View {
        if field.isNumeric, value.doubleValue != nil {
            AdvancedNumericField(
                field: field, value: value, unit: presentation.unit(for: field), title: presentation.title(for: field),
                onSet: { onSet(field.name, $0) }, onValidity: { onValidity(field.name, $0) },
                onCommit: onCommit, onEditingChanged: onEditingChanged,
                onSliderSet: onSliderSet.map { callback in { callback(field.name, $0) } })
        } else if field.kind == .bool, case .boolean(let enabled) = value {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(presentation.title(for: field)).frame(maxWidth: .infinity, alignment: .leading)
                Toggle(
                    "",
                    isOn: Binding(get: { enabled }, set: { onSet(field.name, .boolean($0)); onCommit() })
                )
                .toggleStyle(.checkbox).labelsHidden().frame(width: 88, alignment: .trailing)
                .accessibilityLabel(field.displayTitle)
                .accessibilityIdentifier("advanced.value.\(field.name)")
                Text("").frame(width: 24)
                reset(field, value: value).frame(width: 16)
            }
            .frame(minHeight: 24)
        } else if field.kind == .enumeration {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(presentation.title(for: field)).frame(maxWidth: .infinity, alignment: .leading)
                Picker(
                    field.displayTitle,
                    selection: Binding(
                        get: { field.choiceValue(for: value) },
                        set: { selection in
                            if let selection { onSet(field.name, .integer(selection)); onCommit() }
                        })
                ) {
                    if field.choiceValue(for: value) == nil {
                        Text("Retained value (\(value.entryText))").tag(nil as Int?)
                    }
                    ForEach(field.choices) { choice in
                        let title = choice.title ?? choice.name
                        Text(title.prefix(1).uppercased() + title.dropFirst()).tag(Optional(choice.value))
                    }
                }
                .pickerStyle(.menu).labelsHidden().frame(width: 88, alignment: .trailing)
                .disabled(field.choices.isEmpty).accessibilityLabel(field.displayTitle)
                .accessibilityIdentifier("advanced.value.\(field.name)")
                Text("").frame(width: 24)
                reset(field, value: value).frame(width: 16)
            }
            .frame(minHeight: 24)
        } else {
            readOnly(field, value: field.displayText(for: value))
        }
    }

    private func reset(_ field: ModuleParameterField, value: ModuleParameterValue) -> some View {
        Button {
            if let defaultValue = field.defaultValue, field.accepts(defaultValue) {
                onSet(field.name, defaultValue)
                onCommit()
            }
        } label: {
            Image(systemName: "arrow.counterclockwise")
        }
        .buttonStyle(.borderless)
        .disabled(field.defaultValue.map { field.valuesEqual($0, value) } ?? true)
        .help("Reset \(field.displayTitle) to darktable’s declared default")
        .accessibilityLabel("Reset \(field.displayTitle)")
        .accessibilityIdentifier("advanced.reset.\(field.name)")
    }

    private var metadata: some View {
        DisclosureGroup("Limits & Defaults") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(schema.fields) { field in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(field.displayTitle).font(.callout)
                        if let bounds = field.boundsDescription { Text(bounds) }
                        if let text = defaultText(field) {
                            Text("Default \(text)\(presentation.unit(for: field).map { " " + $0 } ?? "")")
                        }
                        if let value = values[field.name],
                            AdvancedNumericPresentation(field: field).preservesFinerValue(value) {
                            Text("The stored value is finer than hundredths and is preserved until edited.")
                        }
                    }
                }
            }
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true).padding(.top, 6)
        }
    }

    private func defaultText(_ field: ModuleParameterField) -> String? {
        if let defaultValue = field.defaultValue {
            let choice = field.choices.first { $0.value == field.choiceValue(for: defaultValue) }
            return choice?.title ?? choice?.name ?? field.displayText(for: defaultValue)
        }
        return nil
    }

    private func readOnly(_ field: ModuleParameterField, value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(field.displayTitle).font(.body)
            Text(value).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Text("This setting is preserved; its editor is unavailable.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

import SwiftUI

@MainActor
struct AdvancedModuleFields: View {
    let schema: ModuleSchema
    let values: [String: ModuleParameterValue]
    var onSet: (String, ModuleParameterValue) -> Void
    var onValidity: (String, Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            fieldGroup("Values", fields: schema.fields.filter(\.isNumeric))
            fieldGroup(
                "Options", fields: schema.fields.filter { $0.kind == .bool || $0.kind == .enumeration })
            fieldGroup("Retained Parameters", fields: schema.fields.filter { $0.kind == .other })
        }
    }

    @ViewBuilder
    private func fieldGroup(_ title: String, fields: [ModuleParameterField]) -> some View {
        if !fields.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                Text(title).font(.headline)
                ForEach(fields) { field in
                    if let value = values[field.name] {
                        parameter(field, value: value)
                    } else {
                        readOnly(field, value: "Value unavailable")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func parameter(_ field: ModuleParameterField, value: ModuleParameterValue) -> some View {
        if field.isNumeric, value.doubleValue != nil {
            AdvancedNumericField(
                field: field, value: value,
                onSet: { onSet(field.name, $0) }, onValidity: { onValidity(field.name, $0) })
        } else if field.kind == .bool, case .boolean(let enabled) = value {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Toggle(
                        field.displayTitle,
                        isOn: Binding(get: { enabled }, set: { onSet(field.name, .boolean($0)) })
                    )
                    .toggleStyle(.checkbox)
                    .accessibilityIdentifier("advanced.value.\(field.name)")
                    Spacer()
                    reset(field, value: value)
                }
                defaultLabel(field)
            }
        } else if field.kind == .enumeration {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Picker(
                        field.displayTitle,
                        selection: Binding(
                            get: { field.choiceValue(for: value) },
                            set: { selection in
                                if let selection { onSet(field.name, .integer(selection)) }
                            })
                    ) {
                        if field.choiceValue(for: value) == nil {
                            Text("Retained value (\(value.entryText))").tag(nil as Int?)
                        }
                        ForEach(field.choices) { choice in
                            Text(choice.title ?? choice.name).tag(Optional(choice.value))
                        }
                    }
                    .pickerStyle(.menu).disabled(field.choices.isEmpty)
                    .accessibilityIdentifier("advanced.value.\(field.name)")
                    reset(field, value: value)
                }
                defaultLabel(field)
            }
        } else {
            readOnly(field, value: value.entryText)
        }
    }

    private func reset(_ field: ModuleParameterField, value: ModuleParameterValue) -> some View {
        Button {
            if let defaultValue = field.defaultValue, field.accepts(defaultValue) {
                onSet(field.name, defaultValue)
            }
        } label: {
            Image(systemName: "arrow.counterclockwise")
        }
        .buttonStyle(.borderless)
        .disabled(field.defaultValue.map { field.valuesEqual($0, value) } ?? true)
        .help("Reset \(field.displayTitle) to the schema default")
        .accessibilityLabel("Reset \(field.displayTitle)")
        .accessibilityIdentifier("advanced.reset.\(field.name)")
    }

    @ViewBuilder
    private func defaultLabel(_ field: ModuleParameterField) -> some View {
        if let defaultValue = field.defaultValue {
            let choice = field.choices.first { $0.value == field.choiceValue(for: defaultValue) }
            let text = choice?.title ?? choice?.name ?? defaultValue.entryText
            Text("Default \(text)").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func readOnly(_ field: ModuleParameterField, value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(field.displayTitle).font(.body)
            Text(value).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Text("This parameter cannot be edited with the current schema.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

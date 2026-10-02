import SwiftUI

@MainActor
struct AdvancedNumericField: View {
    let field: ModuleParameterField
    let value: ModuleParameterValue
    var unit: String?
    var title: String?
    var onSet: (ModuleParameterValue) -> Void
    var onValidity: (Bool) -> Void
    @State private var draft = ""
    @State private var validationMessage: String?
    @State private var didEdit = false
    @FocusState private var isFocused: Bool

    private var presentation: AdvancedNumericPresentation {
        AdvancedNumericPresentation(field: field, unit: unit)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title ?? field.displayTitle).font(.body).frame(maxWidth: .infinity, alignment: .leading)
                TextField(field.displayTitle, text: Binding(get: { draft }, set: editDraft))
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: 88)
                    .focused($isFocused)
                    .onSubmit(commit)
                    .onExitCommand(perform: discard)
                    .accessibilityIdentifier("advanced.value.\(field.name)")
                    .accessibilityLabel("\(field.displayTitle), value")
                    .help(presentation.preservesFinerValue(value)
                        ? "This stored value is finer than hundredths. It is preserved until you edit."
                        : "Enter up to two decimal places in the displayed unit.")
                Text(unit ?? "").font(.caption).foregroundStyle(.secondary)
                    .frame(width: 24, alignment: .leading)
                resetButton.frame(width: 16)
            }
            .frame(minHeight: 24)
            if let range = field.sliderRange(for: value) {
                slider(range)
            }
            if let validationMessage {
                Label(validationMessage, systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { draft = presentation.text(for: value) }
        .onChange(of: value) { _, updated in
            if !isFocused, validationMessage == nil { draft = presentation.text(for: updated) }
        }
        .onChange(of: draft) { _, text in
            let capped = presentation.cappedEntry(text)
            if capped != text { draft = capped }
        }
        .onChange(of: isFocused) { _, focused in
            if focused {
                if validationMessage == nil { draft = presentation.text(for: value) }
                didEdit = false
            } else {
                commit()
            }
        }
        .onDisappear { onValidity(true) }
    }

    private func slider(_ range: ClosedRange<Double>) -> some View {
        let binding = Binding(get: { value.doubleValue ?? range.lowerBound }, set: updateSlider)
        return Group {
            if field.isInteger, range.upperBound - range.lowerBound <= 20 {
                Slider(value: binding, in: range, step: 1)
            } else {
                Slider(value: binding, in: range)
            }
        }
        .accessibilityLabel(field.displayTitle)
        .accessibilityValue(presentation.text(for: value) + (unit.map { " " + $0 } ?? ""))
        .accessibilityIdentifier("advanced.slider.\(field.name)")
    }

    private var resetButton: some View {
        Button {
            guard let defaultValue = field.defaultValue, field.accepts(defaultValue) else { return }
            isFocused = false
            didEdit = false
            draft = presentation.text(for: defaultValue)
            validationMessage = nil
            onValidity(true)
            onSet(defaultValue)
        } label: {
            Image(systemName: "arrow.counterclockwise")
        }
        .buttonStyle(.borderless)
        .disabled(field.defaultValue.map { field.valuesEqual($0, value) } ?? true)
        .help("Reset \(field.displayTitle) to darktable’s declared default")
        .accessibilityLabel("Reset \(field.displayTitle)")
        .accessibilityIdentifier("advanced.reset.\(field.name)")
    }

    private func editDraft(_ text: String) {
        guard text != draft else { return }
        draft = text
        didEdit = true
        validateDraft()
    }

    private func updateSlider(_ number: Double) {
        guard let updated = presentation.roundedValue(number) else { return }
        didEdit = false
        draft = presentation.text(for: updated)
        validationMessage = nil
        onValidity(true)
        onSet(updated)
    }

    private func validateDraft() {
        let parsed = presentation.parsedValue(presentation.cappedEntry(draft))
        let valid = parsed != nil
        validationMessage =
            valid
            ? nil : "Use a valid \(field.isInteger ? "integer" : "number with at most two decimal places")."
        onValidity(valid)
        if let parsed { onSet(parsed) }
    }

    private func commit() {
        guard didEdit else {
            if validationMessage == nil { draft = presentation.text(for: value) }
            return
        }
        guard let updated = presentation.parsedValue(draft) else {
            validateDraft()
            return
        }
        onSet(updated)
        didEdit = false
        draft = presentation.text(for: updated)
        validationMessage = nil
        onValidity(true)
    }

    private func discard() {
        didEdit = false
        draft = presentation.text(for: value)
        validationMessage = nil
        onValidity(true)
        isFocused = false
    }
}

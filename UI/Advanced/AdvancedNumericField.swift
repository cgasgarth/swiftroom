import SwiftUI

@MainActor
struct AdvancedNumericField: View {
    let field: ModuleParameterField
    let value: ModuleParameterValue
    var onSet: (ModuleParameterValue) -> Void
    var onValidity: (Bool) -> Void
    @State private var draft = ""
    @State private var validationMessage: String?
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(field.displayTitle).font(.body)
                Spacer(minLength: 4)
                TextField(field.displayTitle, text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: 116)
                    .focused($isFocused)
                    .onSubmit(commit)
                    .onExitCommand(perform: discard)
                    .accessibilityIdentifier("advanced.value.\(field.name)")
                    .accessibilityLabel("\(field.displayTitle), exact value")
                resetButton
            }
            if let range = field.sliderRange(for: value) {
                Slider(
                    value: Binding(get: { value.doubleValue ?? range.lowerBound }, set: updateSlider),
                    in: range, step: field.isInteger ? 1 : sliderStep(range)
                )
                .accessibilityLabel(field.displayTitle)
                .accessibilityIdentifier("advanced.slider.\(field.name)")
            }
            if let validationMessage {
                Label(validationMessage, systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .top) {
                if let bounds = field.boundsDescription { Text(bounds) }
                Spacer(minLength: 4)
                if let defaultValue = field.defaultValue { Text("Default \(defaultValue.entryText)") }
            }
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { draft = value.entryText }
        .onChange(of: value) { _, updated in
            if !isFocused { draft = updated.entryText }
        }
        .onChange(of: draft) { _, _ in validateDraft() }
        .onChange(of: isFocused) { _, focused in
            if !focused { commit() }
        }
    }

    private var resetButton: some View {
        Button {
            guard let defaultValue = field.defaultValue, field.accepts(defaultValue) else { return }
            isFocused = false
            draft = defaultValue.entryText
            onSet(defaultValue)
        } label: {
            Image(systemName: "arrow.counterclockwise")
        }
        .buttonStyle(.borderless)
        .disabled(field.defaultValue.map { field.valuesEqual($0, value) } ?? true)
        .help("Reset \(field.displayTitle) to the schema default")
        .accessibilityLabel("Reset \(field.displayTitle)")
        .accessibilityIdentifier("advanced.reset.\(field.name)")
    }

    private func sliderStep(_ range: ClosedRange<Double>) -> Double {
        max(0.000_001, min(0.01, (range.upperBound - range.lowerBound) / 1000))
    }

    private func updateSlider(_ number: Double) {
        let updated: ModuleParameterValue
        if field.isInteger {
            guard let integer = Int(exactly: number.rounded()) else { return }
            updated = .integer(integer)
        } else {
            updated = .number(number)
        }
        guard field.accepts(updated) else { return }
        draft = updated.entryText
        onSet(updated)
    }

    private func validateDraft() {
        let parsed = field.parsedValue(draft)
        let valid = parsed != nil
        validationMessage =
            valid
            ? nil : field.boundsDescription ?? "Enter a finite \(field.isInteger ? "integer" : "number")."
        onValidity(valid)
        if let parsed { onSet(parsed) }
    }

    private func commit() {
        guard let updated = field.parsedValue(draft) else {
            validateDraft()
            return
        }
        onSet(updated)
        draft = updated.entryText
        validationMessage = nil
        onValidity(true)
    }

    private func discard() {
        draft = value.entryText
        validationMessage = nil
        onValidity(true)
        isFocused = false
    }
}

import SwiftUI

@MainActor
struct AdvancedNumericField: View {
    let field: ModuleParameterField
    let value: ModuleParameterValue
    var onSet: (ModuleParameterValue) -> Void
    var onValidity: (Bool) -> Void
    @State private var draft = ""
    @State private var validationMessage: String?
    @State private var didEdit = false
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(field.displayTitle).font(.body)
                Spacer(minLength: 4)
                TextField(field.displayTitle, text: Binding(get: { draft }, set: editDraft))
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: 116)
                    .focused($isFocused)
                    .onSubmit(commit)
                    .onExitCommand(perform: discard)
                    .accessibilityIdentifier("advanced.value.\(field.name)")
                    .accessibilityLabel("\(field.displayTitle), exact value")
                    .help("Exact value: \(value.entryText)")
                resetButton
            }
            if let range = field.sliderRange(for: value) {
                slider(range)
            }
            if let validationMessage {
                Label(validationMessage, systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { draft = field.displayText(for: value) }
        .onChange(of: value) { _, updated in
            if !isFocused, validationMessage == nil { draft = field.displayText(for: updated) }
        }
        .onChange(of: isFocused) { _, focused in
            if focused {
                if validationMessage == nil { draft = value.entryText }
                didEdit = false
            } else {
                commit()
            }
        }
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
        .accessibilityIdentifier("advanced.slider.\(field.name)")
    }

    private var resetButton: some View {
        Button {
            guard let defaultValue = field.defaultValue, field.accepts(defaultValue) else { return }
            isFocused = false
            didEdit = false
            draft = field.displayText(for: defaultValue)
            validationMessage = nil
            onValidity(true)
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

    private func editDraft(_ text: String) {
        draft = text
        didEdit = true
        validateDraft()
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
        didEdit = false
        draft = isFocused ? updated.entryText : field.displayText(for: updated)
        validationMessage = nil
        onValidity(true)
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
        guard didEdit else {
            if validationMessage == nil { draft = isFocused ? value.entryText : field.displayText(for: value) }
            return
        }
        guard let updated = field.parsedValue(draft) else {
            validateDraft()
            return
        }
        onSet(updated)
        didEdit = false
        draft = isFocused ? updated.entryText : field.displayText(for: updated)
        validationMessage = nil
        onValidity(true)
    }

    private func discard() {
        didEdit = false
        draft = field.displayText(for: value)
        validationMessage = nil
        onValidity(true)
        isFocused = false
    }
}

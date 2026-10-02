import SwiftUI

@MainActor
struct MaskGroupFields: View {
    @ObservedObject var model: MaskInspectorModel
    @State private var memberToAdd: Int32?

    private var members: [MaskGroupMember] {
        if case .group(let members) = model.draftGeometry { return members }
        return []
    }
    private var availableForms: [MaskForm] { model.state?.forms.filter { model.canAddMember($0.id) } ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Members are combined in this order.").font(.caption).foregroundStyle(.secondary)
            if members.isEmpty {
                Text("This group has no members.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(Array(members.enumerated()), id: \.offset) { index, member in
                VStack(alignment: .leading, spacing: 10) {
                    memberHeader(index, member: member)
                    Picker(
                        "Combine",
                        selection: Binding(
                            get: { member.operation },
                            set: { operation in
                                model.updateMember(index) { $0.operation = operation }
                            })
                    ) {
                        ForEach(MaskGroupOperation.allCases, id: \.self) { operation in
                            Text(title(operation)).tag(operation)
                        }
                    }.accessibilityIdentifier("masks.member.\(index).operation")
                    MaskNumericControl(
                        title: "Member opacity", fieldID: "member.\(index).opacity", range: 0...1,
                        value: Binding(
                            get: { member.opacity },
                            set: { opacity in
                                model.updateMember(index) { $0.opacity = opacity }
                            }), onValidity: model.setValidity)
                    Toggle(
                        "Enabled",
                        isOn: Binding(
                            get: { member.enabled },
                            set: { enabled in
                                model.updateMember(index) { $0.enabled = enabled }
                            })
                    ).accessibilityIdentifier("masks.member.\(index).enabled")
                    Toggle(
                        "Inverted",
                        isOn: Binding(
                            get: { member.inverted },
                            set: { inverted in
                                model.updateMember(index) { $0.inverted = inverted }
                            })
                    ).accessibilityIdentifier("masks.member.\(index).inverted")
                    Toggle(
                        "Visible in engine mask view",
                        isOn: Binding(
                            get: { member.visible },
                            set: { visible in
                                model.updateMember(index) { $0.visible = visible }
                            })
                    ).accessibilityIdentifier("masks.member.\(index).visible")
                    Divider()
                }
            }
            Picker("Add member", selection: $memberToAdd) {
                Text("Choose a mask").tag(Optional<Int32>.none)
                ForEach(availableForms) { form in Text(form.name).tag(Optional(form.id)) }
            }.accessibilityIdentifier("masks.member.choice")
            Button("Add Member") {
                if let memberToAdd { model.addMember(memberToAdd) }
            }
            .disabled(memberToAdd.map { !model.canAddMember($0) } ?? true)
            .accessibilityIdentifier("masks.member.add")
        }
    }

    private func memberHeader(_ index: Int, member: MaskGroupMember) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(
                "\(index + 1). \(model.state?.forms.first { $0.id == member.maskID }?.name ?? "Missing mask")"
            )
            .font(.headline)
            HStack {
                Button {
                    model.moveMember(index, by: -1)
                } label: {
                    Image(systemName: "arrow.up")
                }
                .disabled(index == 0).help("Move member up")
                .accessibilityLabel("Move member \(index + 1) up")
                .accessibilityIdentifier("masks.member.\(index).up")
                Button {
                    model.moveMember(index, by: 1)
                } label: {
                    Image(systemName: "arrow.down")
                }
                .disabled(index == members.count - 1).help("Move member down")
                .accessibilityLabel("Move member \(index + 1) down")
                .accessibilityIdentifier("masks.member.\(index).down")
                Spacer()
                Button("Remove Member", role: .destructive) { model.removeMember(index) }
                    .accessibilityIdentifier("masks.member.\(index).remove")
            }
        }
    }

    private func title(_ operation: MaskGroupOperation) -> String {
        switch operation {
        case .union: return "Union"
        case .intersection: return "Intersection"
        case .difference: return "Difference"
        case .exclusion: return "Exclusion"
        case .sum: return "Sum"
        }
    }
}

import SwiftUI

extension MaskForm {
    var geometryTitle: String {
        switch geometry {
        case .circle: return "Circle"
        case .ellipse: return "Ellipse"
        case .gradient: return "Gradient"
        case .group: return "Group"
        case nil: return "Unsupported geometry"
        }
    }
    var symbol: String {
        switch geometry {
        case .circle: return "circle"
        case .ellipse: return "oval"
        case .gradient: return "circle.lefthalf.filled"
        case .group: return "square.stack"
        case nil: return "lock"
        }
    }
}

@MainActor
struct MaskGeometryFields: View {
    @ObservedObject var model: MaskInspectorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch model.draftGeometry {
            case .circle(let circle): circleFields(circle)
            case .ellipse(let ellipse): ellipseFields(ellipse)
            case .gradient(let gradient): gradientFields(gradient)
            case .group: MaskGroupFields(model: model)
            case nil:
                Text("This geometry is read-only. Its original point data and fields are retained.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .disabled(!model.canEdit)
        .id(model.draftRevision)
    }

    private func circleFields(_ circle: CircleMask) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            number("Center X", id: "centerX", value: circle.center.horizontal, range: 0...1) {
                var updated = circle
                updated.center.horizontal = $0
                model.setGeometry(.circle(updated))
            }
            number("Center Y", id: "centerY", value: circle.center.vertical, range: 0...1) {
                var updated = circle
                updated.center.vertical = $0
                model.setGeometry(.circle(updated))
            }
            number("Radius", id: "radius", value: circle.radius, range: 0.000_001...1) {
                var updated = circle
                updated.radius = $0
                model.setGeometry(.circle(updated))
            }
            number("Feather", id: "feather", value: circle.feather, range: 0...1) {
                var updated = circle
                updated.feather = $0
                model.setGeometry(.circle(updated))
            }
        }
    }

    private func ellipseFields(_ ellipse: EllipseMask) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            number("Center X", id: "centerX", value: ellipse.center.horizontal, range: 0...1) {
                var updated = ellipse
                updated.center.horizontal = $0
                model.setGeometry(.ellipse(updated))
            }
            number("Center Y", id: "centerY", value: ellipse.center.vertical, range: 0...1) {
                var updated = ellipse
                updated.center.vertical = $0
                model.setGeometry(.ellipse(updated))
            }
            number("Radius X", id: "radiusX", value: ellipse.radius.horizontal, range: 0.000_001...1) {
                var updated = ellipse
                updated.radius.horizontal = $0
                model.setGeometry(.ellipse(updated))
            }
            number("Radius Y", id: "radiusY", value: ellipse.radius.vertical, range: 0.000_001...1) {
                var updated = ellipse
                updated.radius.vertical = $0
                model.setGeometry(.ellipse(updated))
            }
            number("Rotation (degrees)", id: "rotation", value: ellipse.rotation, range: -360...360) {
                var updated = ellipse
                updated.rotation = $0
                model.setGeometry(.ellipse(updated))
            }
            Picker(
                "Feather mode",
                selection: Binding(
                    get: { ellipse.featherMode },
                    set: {
                        var updated = ellipse
                        updated.featherMode = $0
                        model.setGeometry(.ellipse(updated))
                    })
            ) {
                Text("Equidistant").tag(EllipseFeather.equidistant)
                Text("Proportional").tag(EllipseFeather.proportional)
            }.accessibilityIdentifier("masks.ellipse.featherMode")
            number(
                "Feather", id: "feather", value: ellipse.feather,
                range: 0...(ellipse.featherMode == .equidistant ? 1 : 10)
            ) {
                var updated = ellipse
                updated.feather = $0
                model.setGeometry(.ellipse(updated))
            }
        }
    }

    private func gradientFields(_ gradient: GradientMask) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            number("Anchor X", id: "anchorX", value: gradient.anchor.horizontal, range: 0...1) {
                var updated = gradient
                updated.anchor.horizontal = $0
                model.setGeometry(.gradient(updated))
            }
            number("Anchor Y", id: "anchorY", value: gradient.anchor.vertical, range: 0...1) {
                var updated = gradient
                updated.anchor.vertical = $0
                model.setGeometry(.gradient(updated))
            }
            number("Rotation (degrees)", id: "rotation", value: gradient.rotation, range: -360...360) {
                var updated = gradient
                updated.rotation = $0
                model.setGeometry(.gradient(updated))
            }
            number("Compression", id: "compression", value: gradient.compression, range: 0.001...1) {
                var updated = gradient
                updated.compression = $0
                model.setGeometry(.gradient(updated))
            }
            number("Steepness", id: "steepness", value: gradient.steepness, range: 0...1) {
                var updated = gradient
                updated.steepness = $0
                model.setGeometry(.gradient(updated))
            }
            number("Curvature", id: "curvature", value: gradient.curvature, range: -2...2) {
                var updated = gradient
                updated.curvature = $0
                model.setGeometry(.gradient(updated))
            }
            Picker(
                "Transition",
                selection: Binding(
                    get: { gradient.transition },
                    set: {
                        var updated = gradient
                        updated.transition = $0
                        model.setGeometry(.gradient(updated))
                    })
            ) {
                Text("Linear").tag(GradientTransition.linear)
                Text("Sigmoidal").tag(GradientTransition.sigmoidal)
            }.accessibilityIdentifier("masks.gradient.transition")
        }
    }

    private func number(
        _ title: String, id: String, value: Double, range: ClosedRange<Double>,
        set: @escaping @MainActor (Double) -> Void
    ) -> some View {
        MaskNumericControl(
            title: title, fieldID: id, range: range,
            value: Binding(get: { value }, set: set), onValidity: model.setValidity)
    }
}

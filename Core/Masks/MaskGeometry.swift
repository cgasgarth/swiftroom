import Foundation

struct MaskPoint: Codable, Equatable, Sendable {
    var horizontal: Double
    var vertical: Double

    private enum CodingKeys: String, CodingKey {
        case horizontal = "x", vertical = "y"
    }
}

struct CircleMask: Codable, Equatable, Sendable {
    var center: MaskPoint
    var radius: Double
    var feather: Double
}

enum EllipseFeather: Int, Codable, CaseIterable, Sendable {
    case equidistant = 0, proportional = 1
}

struct EllipseMask: Codable, Equatable, Sendable {
    var center: MaskPoint
    var radius: MaskPoint
    var rotation: Double
    var feather: Double
    var featherMode: EllipseFeather
}

enum GradientTransition: Int, Codable, CaseIterable, Sendable {
    case linear = 1, sigmoidal = 2
}

struct GradientMask: Codable, Equatable, Sendable {
    var anchor: MaskPoint
    var rotation: Double
    var compression: Double
    var steepness: Double
    var curvature: Double
    var transition: GradientTransition
}

enum MaskGroupOperation: Int, Codable, CaseIterable, Sendable {
    case union = 8, intersection = 16, difference = 32, exclusion = 64, sum = 128
}

struct MaskGroupMember: Codable, Equatable, Sendable {
    var maskID: Int32
    var opacity: Double
    var operation: MaskGroupOperation
    var inverted: Bool = false
    var enabled: Bool = true
    var visible: Bool = true
    var preservedFlags: UInt32 = 0
}

enum MaskGeometry: Equatable, Sendable {
    case circle(CircleMask)
    case ellipse(EllipseMask)
    case gradient(GradientMask)
    case group([MaskGroupMember])
    case path([BezierMaskPoint])
    case brush([BrushMaskPoint])
}

extension MaskGeometry: Codable {
    private enum CodingKeys: String, CodingKey { case kind, value }
    private enum Kind: String, Codable { case circle, ellipse, gradient, group, path, brush }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .circle: self = .circle(try container.decode(CircleMask.self, forKey: .value))
        case .ellipse: self = .ellipse(try container.decode(EllipseMask.self, forKey: .value))
        case .gradient: self = .gradient(try container.decode(GradientMask.self, forKey: .value))
        case .group: self = .group(try container.decode([MaskGroupMember].self, forKey: .value))
        case .path: self = .path(try container.decode([BezierMaskPoint].self, forKey: .value))
        case .brush: self = .brush(try container.decode([BrushMaskPoint].self, forKey: .value))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .circle(let value):
            try container.encode(Kind.circle, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .ellipse(let value):
            try container.encode(Kind.ellipse, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .gradient(let value):
            try container.encode(Kind.gradient, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .group(let value):
            try container.encode(Kind.group, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .path(let value):
            try container.encode(Kind.path, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .brush(let value):
            try container.encode(Kind.brush, forKey: .kind)
            try container.encode(value, forKey: .value)
        }
    }
}

import Foundation

enum BlendMode: UInt32, Codable, CaseIterable, Sendable {
    case lighten = 2, darken = 3, multiply = 4, average = 5, add = 6, subtract = 7
    case screen = 9, difference = 23, normal = 24
}

struct BlendMaskMode: OptionSet, Codable, Equatable, Sendable {
    var rawValue: UInt32
    static let enabled = Self(rawValue: 1)
    static let drawn = Self(rawValue: 2)
    static let parametric = Self(rawValue: 4)
    static let raster = Self(rawValue: 8)

    init(rawValue: UInt32) { self.rawValue = rawValue }

    init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(UInt32.self)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

struct BlendState: Codable, Equatable, Sendable {
    var moduleID: UUID
    var version: Int
    var colorSpace: Int
    var mode: UInt32
    var opacity: Double
    var maskMode: BlendMaskMode
    var maskID: Int32
    var maskCombine: UInt32
    var parameters: Data
    var supportsDrawnMasks: Bool

    var supportedModes: [BlendMode] {
        guard (1...4).contains(colorSpace) else { return [] }
        return BlendMode.allCases.filter {
            if colorSpace == 4 { return $0 != .lighten && $0 != .darken }
            return $0 != .average
        }
    }
}

struct BlendPatch: Codable, Equatable, Sendable {
    var mode: BlendMode?
    var reversed: Bool?
    var opacity: Double?
    var maskMode: BlendMaskMode?
    var maskID: Int32?
    var maskCombine: UInt32?
}

struct ModuleBlendMutation: Equatable, Sendable {
    var moduleID: UUID
    var patch: BlendPatch
}

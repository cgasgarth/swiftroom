import Foundation

enum BezierPointState: Int, Codable, CaseIterable, Sendable {
    case normal = 1, user = 2
}

struct BezierMaskPoint: Codable, Equatable, Sendable {
    var corner: MaskPoint
    var controlIn: MaskPoint
    var controlOut: MaskPoint
    var feather: MaskPoint
    var state: BezierPointState = .user
}

struct BrushMaskPoint: Codable, Equatable, Sendable {
    var curve: BezierMaskPoint
    var density: Double
    var hardness: Double
}

import CoreGraphics
import CryptoKit
import Foundation
import ImageIO

struct ImageEvidence {
    let width: Int
    let height: Int
    let profile: Data
    let pixelDigest: String
    let averageLuma: Double

    init(url: URL) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            throw WorkflowFailure("Cannot decode exported image dimensions.")
        }
        self.width = width
        self.height = height
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 128,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let profile = image.colorSpace?.copyICCData() as Data?,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: 128, height: 128, bitsPerComponent: 8, bytesPerRow: 512,
                space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let pixels = context.data else {
            throw WorkflowFailure("Cannot decode ICC-tagged image pixels.")
        }
        self.profile = profile
        context.draw(image, in: CGRect(x: 0, y: 0, width: 128, height: 128))
        let bytes = Data(bytes: pixels, count: 128 * 128 * 4)
        pixelDigest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        averageLuma = bytes.withUnsafeBytes { buffer in
            let values = buffer.bindMemory(to: UInt8.self)
            var total = 0.0
            for offset in stride(from: 0, to: values.count, by: 4) {
                total += 0.2126 * Double(values[offset]) + 0.7152 * Double(values[offset + 1])
                    + 0.0722 * Double(values[offset + 2])
            }
            return total / Double(128 * 128 * 255)
        }
    }
}

struct WorkflowFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func requireWorkflow(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw WorkflowFailure(message) }
}

func fileDigest(_ url: URL) throws -> Data {
    Data(SHA256.hash(data: try Data(contentsOf: url)))
}

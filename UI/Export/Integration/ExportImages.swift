#if EXPORT_INTEGRATION
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ExportImages {
    static func fixture(at url: URL) throws {
        let width = 480
        let height = 320
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for row in 0..<height {
            for column in 0..<width {
                let offset = (row * width + column) * 4
                bytes[offset] = UInt8((column * 13 + row * 7) % 256)
                bytes[offset + 1] = UInt8((column * 3 + row * 17) % 256)
                bytes[offset + 2] = UInt8((column + row * 5) % 256)
                bytes[offset + 3] = 255
            }
        }
        guard let profile = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4, space: profile,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let destination = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.tiff.identifier as CFString, 1, nil)
        else { throw ExportPresentationError.invalid("Could not create the disposable image fixture.") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ExportPresentationError.invalid("Could not write the disposable image fixture.")
        }
    }

    static func inspect(_ result: ExportResult, format: ExportFormat, maximum: Int?) throws -> [String: String] {
        guard let source = CGImageSourceCreateWithURL(result.destinationURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let profileName = properties[kCGImagePropertyProfileName] as? String,
              let profile = image.colorSpace?.copyICCData() else {
            throw ExportPresentationError.invalid("The exported image did not reopen with an ICC profile.")
        }
        guard image.width == result.pixelWidth, image.height == result.pixelHeight,
              image.bitsPerComponent == (format == .jpeg ? 8 : 16),
              maximum.map({ max(image.width, image.height) <= $0 }) ?? true else {
            throw ExportPresentationError.invalid("The export dimensions or bit depth did not match its result.")
        }
        return ["name": result.destinationURL.lastPathComponent, "profile": profileName,
                "iccSHA256": SHA256.hash(data: profile as Data).description,
                "dimensions": "\(image.width)×\(image.height)", "depth": "\(image.bitsPerComponent)"]
    }

    static func hash(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).description
    }

    static func pixels(_ url: URL) throws -> String {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let data = image.dataProvider?.data else {
            throw ExportPresentationError.invalid("The exported pixels could not be read.")
        }
        return SHA256.hash(data: data as Data).description
    }
}
#endif

import Foundation
import ImageIO

enum ImageValidation {
    static func validate(_ url: URL, expectedICC: Data?) throws -> ValidatedImage {
        guard let expectedICC, !expectedICC.isEmpty,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let profileName = properties[kCGImagePropertyProfileName] as? String,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width > 0, image.height > 0,
              try EmbeddedICC.read(url, expectedLength: expectedICC.count) == expectedICC else {
            throw PhotoEngineError.invalidOutput("darktable output does not contain the requested ICC profile.")
        }
        return ValidatedImage(width: image.width, height: image.height, profileName: profileName)
    }
}

struct ValidatedImage {
    var width: Int
    var height: Int
    var profileName: String
}

import Foundation
import UIKit

// Where an attached image landed on the computer (#88; `POST /api/files/upload`).
struct UploadReceipt: Decodable, Equatable, Sendable {
    let path: String
    let bytes: Int
}

// An image picked for the composer, made small enough to send from a
// phone on a mobile network: longest side 2048 px, JPEG. A screenshot
// becomes a few hundred kilobytes; a 12 MP photo well under a megabyte.
enum ComposerImage {
    static let maximumSide: CGFloat = 2048
    static let quality: CGFloat = 0.8
    static let mime = "image/jpeg"

    static func jpegData(from original: Data) -> Data? {
        guard let image = UIImage(data: original) else { return nil }
        return jpegData(from: image)
    }

    static func jpegData(from image: UIImage) -> Data? {
        let size = image.size
        let longest = max(size.width, size.height)
        guard longest > maximumSide else { return image.jpegData(compressionQuality: quality) }
        let scale = maximumSide / longest
        let target = CGSize(width: (size.width * scale).rounded(.down), height: (size.height * scale).rounded(.down))
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let shrunk = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return shrunk.jpegData(compressionQuality: quality)
    }

    // The words the composer shows the first time an image goes to a
    // computer: where it went, so nothing is saved somewhere unexpected.
    static func savedNote(computer: String) -> String {
        "Saved on \(computer) in the project's .tavi/uploads folder, kept out of git."
    }
}

@testable import Tavi
import Testing
import UIKit

// An attached image is shrunk on the phone before it travels (#88).
struct ComposerImageTests {
    private func image(width: CGFloat, height: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    @Test func aLargeImageComesOutAtTheCapAndSmallerOnesUntouched() throws {
        let big = try #require(ComposerImage.jpegData(from: image(width: 4000, height: 3000)))
        let shrunk = try #require(UIImage(data: big))
        #expect(shrunk.size.width == 2048)
        #expect(shrunk.size.height == 1536)

        let tall = try #require(ComposerImage.jpegData(from: image(width: 1000, height: 5000)))
        #expect(UIImage(data: tall)?.size.height == 2048)
        #expect(UIImage(data: tall)?.size.width == 409)

        let small = try #require(ComposerImage.jpegData(from: image(width: 800, height: 600)))
        #expect(UIImage(data: small)?.size == CGSize(width: 800, height: 600))
        // Bytes in, not an image: nothing out, never a crash.
        #expect(ComposerImage.jpegData(from: Data("not an image".utf8)) == nil)
    }

    @Test func theNoteSaysWhereTheImageWent() {
        #expect(ComposerImage.savedNote(computer: "MacBook Air") == "Saved on MacBook Air in the project's .tavi/uploads folder, kept out of git.")
        #expect(ComposerImage.mime == "image/jpeg")
    }
}

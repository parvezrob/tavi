import Foundation
import PhotosUI
import SwiftUI
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

extension TerminalSessionView {
    // The paperclip (#88): the photo library, then the image goes to the
    // agent's own folder and its path lands in the message, since the
    // agent reads an image when the prompt names one. Only for an agent
    // pane in a folder the host knows; a plain shell has nowhere to put it.
    var attachButton: some View {
        let busy = attachingImage
        return PhotosPicker(selection: $pickedImage, matching: .images, photoLibrary: .shared()) {
            if busy {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "paperclip")
                    .font(.title3)
            }
        }
        .disabled(attachingImage || identity == nil || agentDirectory?.filesClient == nil || !controller.connectionState.canSubmitInput)
        .accessibilityLabel("Attach an image")
        .accessibilityIdentifier("terminal.composerAttach")
        .onChange(of: pickedImage) { _, item in
            guard let item else { return }
            pickedImage = nil
            Task { await attach(item) }
        }
    }

    private func attach(_ item: PhotosPickerItem) async {
        guard let agent = identity, let client = agentDirectory?.filesClient else { return }
        attachingImage = true
        composerError = nil
        defer { attachingImage = false }
        guard let original = try? await item.loadTransferable(type: Data.self),
              let jpeg = ComposerImage.jpegData(from: original) else {
            composerError = "That image could not be read."
            return
        }
        switch await client.upload(cwd: agent.cwd, data: jpeg, mime: ComposerImage.mime) {
        case let .value(receipt):
            let separator = composerText.isEmpty || composerText.hasSuffix(" ") || composerText.hasSuffix("\n") ? "" : " "
            composerText += "\(separator)\(receipt.path) "
            composerNote = ComposerImage.savedNote(computer: computerName ?? "the computer")
        case let .refused(_, refusal):
            composerError = refusal.error
        case let .failure(reason):
            composerError = reason
        }
    }
}

import PDFKit
import Sempere
import SwiftUI

/// A small preview of a blob in Settings → Storage: images and the first
/// page of a PDF are decrypted (verified, in memory only,
/// `AppModel.attachmentPreviewData`) and drawn small; other kinds show an icon.
struct AttachmentThumbnail: View {
    let note: UUID
    let fileName: String
    let kind: BlobKind
    @AppModelEnvironment private var model
    @State private var image: UIImage?

    static let side: CGFloat = 44

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: Self.symbol(kind)).font(.title3).foregroundStyle(.secondary)
            }
        }
        .frame(width: Self.side, height: Self.side)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: fileName) {
            guard let data = await model.attachmentPreviewData(note: note, fileName: fileName, kind: kind) else { return }
            let side = Self.side * 3
            image = await Task.detached(priority: .utility) { Thumb(image: Self.thumbnail(data, kind: kind, side: side)) }.value.image
        }
        .accessibilityHidden(true)
    }

    /// A finished thumbnail handed back from its background task (never touched there again).
    private struct Thumb: @unchecked Sendable { let image: UIImage? }

    /// The SF Symbol of a kind with no picture.
    static func symbol(_ kind: BlobKind) -> String {
        switch kind {
        case .image: return "photo"
        case .pdf: return "doc.richtext"
        case .audio: return "waveform"
        case .video: return "film"
        case .transcript: return "text.quote"
        default: return "doc"
        }
    }

    /// A picture at most `side` points across, or nil when the bytes are not one.
    nonisolated static func thumbnail(_ data: Data, kind: BlobKind, side: CGFloat) -> UIImage? {
        let size = CGSize(width: side, height: side)
        if kind == .pdf {
            return PDFDocument(data: data)?.page(at: 0)?.thumbnail(of: size, for: .cropBox)
        }
        guard let picture = UIImage(data: data), picture.size.width > 0, picture.size.height > 0 else { return nil }
        let scale = min(side / picture.size.width, side / picture.size.height, 1)
        return picture.preparingThumbnail(of: CGSize(width: max(1, picture.size.width * scale),
                                                     height: max(1, picture.size.height * scale)))
    }
}

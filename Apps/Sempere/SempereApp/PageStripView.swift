import Sempere
import PencilKit
import SwiftUI
import UIKit

/// The pages of a paged note as thumbnails, top to bottom: tap to show a
/// page, drag to reorder, swipe or context menu to delete, duplicate or add a
/// page after it. Every gesture is one delta through `NoteEditor`.
struct PageStripView: View {
    let editor: NoteEditor

    var body: some View {
        ScrollViewReader { proxy in
            list
                .onChange(of: editor.pageIndex) { _, index in
                    // The current page follows the canvas's scroll: keep its thumbnail in view.
                    guard editor.pages.indices.contains(index) else { return }
                    withAnimation { proxy.scrollTo(editor.pages[index].id) }
                }
        }
    }

    private var list: some View {
        List {
            ForEach(Array(editor.pages.enumerated()), id: \.element.id) { index, page in
                Button {
                    editor.selectPage(index)
                } label: {
                    PageStripRow(editor: editor, page: page, number: index + 1, selected: index == editor.pageIndex)
                }
                .buttonStyle(.plain)
                .listRowBackground(index == editor.pageIndex ? SwiftUI.Color.accentColor.opacity(0.15) : nil)
                .contextMenu {
                    if !editor.isReadOnly {
                        Button("Add Page After", systemImage: "doc.badge.plus") { editor.insertPage(at: index + 1) }
                        Button("Duplicate", systemImage: "plus.square.on.square") { editor.duplicatePage(page.id) }
                        Button("Delete", systemImage: "trash", role: .destructive) { editor.deletePage(page.id) }
                            .disabled(!editor.canDeletePage)
                    }
                }
                .accessibilityIdentifier("pageStrip.\(index + 1)")
            }
            .onMove { from, to in
                guard let first = from.first, from.count == 1 else { return }
                editor.movePage(from: first, to: PageStrip.targetIndex(from: first, toOffset: to))
            }
            .onDelete { offsets in
                for i in offsets.sorted(by: >) where editor.pages.indices.contains(i) {
                    editor.deletePage(editor.pages[i].id)
                }
            }
            .moveDisabled(editor.isReadOnly)
            .deleteDisabled(!editor.canDeletePage)
        }
        .listStyle(.plain)
        .safeAreaInset(edge: .bottom) {
            if !editor.isReadOnly {
                VStack(spacing: 6) {
                    if !editor.deletedPages.isEmpty {
                        Button("Undo Delete Page", systemImage: "arrow.uturn.backward") { editor.undoDeletePage() }
                    }
                    Button("Add Page at End", systemImage: "doc.badge.plus") { editor.addPage() }
                }
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(.bar)
            }
        }
    }
}

private struct PageStripRow: View {
    let editor: NoteEditor
    let page: Page
    let number: Int
    let selected: Bool
    @Environment(\.displayScale) private var displayScale
    private let width: CGFloat = 120

    var body: some View {
        let strokes = editor.thumbnailStrokes(of: page)
        let paper = editor.displayedPaper(of: page)
        let height = CGFloat(PageStrip.thumbnailHeight(width: Double(width), pageSize: editor.pageSize))
        VStack(spacing: 4) {
            Image(uiImage: PageThumbnail.image(strokes: strokes, paper: paper, pageSize: editor.pageSize,
                                               size: CGSize(width: width, height: height), scale: displayScale,
                                               key: "\(editor.sessionID)-\(page.id)-\(editor.inkRevisions[page.id] ?? 0)-\(strokes.count)"))
                .resizable()
                .frame(width: width, height: height)
                .overlay(Rectangle().stroke(selected ? SwiftUI.Color.accentColor : SwiftUI.Color.secondary.opacity(0.5),
                                            lineWidth: selected ? 2 : 1))
            Text("\(number)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Page \(number)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A page drawn small: paper (`PaperImage`) and ink (PencilKit's own
/// rendering, light appearance, as on the canvas). With a `key` (the page and
/// its ink revision), images are cached, so a stroke redraws only its page.
@MainActor
enum PageThumbnail {
    private static let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 300
        return c
    }()

    static func image(strokes: [Stroke], paper: Paper, pageSize: PageSize, size: CGSize, scale: CGFloat,
                      key: String? = nil) -> UIImage {
        let full = key.map { "\($0)|\(paper)|\(pageSize)|\(Int(size.width))x\(Int(size.height))@\(scale)" as NSString }
        if let full, let hit = cache.object(forKey: full) { return hit }
        let image = render(strokes: strokes, paper: paper, pageSize: pageSize, size: size, scale: scale)
        if let full { cache.setObject(image, forKey: full) }
        return image
    }

    private static func render(strokes: [Stroke], paper: Paper, pageSize: PageSize, size: CGSize, scale: CGFloat) -> UIImage {
        let page = CGRect(x: 0, y: 0, width: CGFloat(pageSize.width.isFinite && pageSize.width > 0 ? pageSize.width : 612),
                          height: CGFloat(pageSize.sheetHeight))
        let background = PaperImage.image(for: paper, size: size, scale: scale)
        var ink: UIImage?
        if !strokes.isEmpty {
            let drawing = PKDrawing(strokes: strokes.map(StrokeConversion.pkStroke))
            UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
                ink = drawing.image(from: page, scale: scale * size.width / page.width)
            }
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            background.draw(in: CGRect(origin: .zero, size: size))
            ink?.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

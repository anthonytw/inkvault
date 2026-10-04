import Foundation
import InkVault
@testable import InkRender

enum T {
    static func pt(_ x: Double, _ y: Double, w: Double = 2, o: Double = 1) -> StrokePoint {
        StrokePoint(x: x, y: y, w: w, h: w, o: o)
    }

    static func stroke(_ pts: [StrokePoint], tool: InkTool = .pen, width: Double = 2,
                       color: Color = .black, transform: Transform? = nil) -> Stroke {
        Stroke(ink: Ink(tool: tool, color: color, width: width), points: pts, transform: transform)
    }

    static func meta(title: String = "Test", paper: Paper = .ruled, size: PageSize = PageSize(width: 200, height: 300)) -> NoteMeta {
        NoteMeta(title: title, created: Date(timeIntervalSince1970: 0), paper: paper, pageSize: size)
    }

    static func note(pages: [[Stroke]], meta: NoteMeta = meta()) -> NoteState {
        NoteState(meta: meta, pages: pages.enumerated().map { Page(order: "a\($0.offset)", strokes: $0.element) })
    }

    static var fixtureDir: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
    }

    static func loadSampleNote() throws -> NoteState {
        let data = try Data(contentsOf: fixtureDir.appendingPathComponent("sample-note.json"))
        return try InkJSON.decoder().decode(NoteState.self, from: data)
    }

    static func latin1(_ d: Data) -> String { String(data: d, encoding: .isoLatin1) ?? "" }
}

import Foundation
import InkVault
import Observation

/// One adjustable number of a paper, with the range and step the picker's
/// slider uses (ranges are `Paper.Limits`).
enum PaperParameter: String, CaseIterable, Identifiable {
    case spacing, lineWidth, dotRadius, marginLeft, marginTop, cueWidth, summaryHeight, staffSpacing, staffGap

    var id: String { rawValue }

    var title: String {
        switch self {
        case .spacing: return "Spacing"
        case .lineWidth: return "Line width"
        case .dotRadius: return "Dot size"
        case .marginLeft: return "Left margin"
        case .marginTop: return "Top margin"
        case .cueWidth: return "Cue column"
        case .summaryHeight: return "Summary area"
        case .staffSpacing: return "Staff line spacing"
        case .staffGap: return "Space between staves"
        }
    }

    var range: ClosedRange<Double> {
        switch self {
        case .spacing: return Paper.Limits.spacing
        case .lineWidth: return Paper.Limits.lineWidth
        case .dotRadius: return Paper.Limits.dotRadius
        case .marginLeft, .marginTop: return Paper.Limits.margin
        case .cueWidth: return Paper.Limits.cueWidth
        case .summaryHeight: return Paper.Limits.summaryHeight
        case .staffSpacing: return Paper.Limits.staffSpacing
        case .staffGap: return Paper.Limits.staffGap
        }
    }

    var step: Double {
        switch self {
        case .lineWidth, .dotRadius: return 0.05
        case .staffSpacing: return 0.5
        default: return 1
        }
    }

    /// Where the value lives in a `Paper`.
    var keyPath: WritableKeyPath<Paper, Double> {
        switch self {
        case .spacing: return \.spacing
        case .lineWidth: return \.lineWidth
        case .dotRadius: return \.dotRadius
        case .marginLeft: return \.marginLeft
        case .marginTop: return \.marginTop
        case .cueWidth: return \.cueWidth
        case .summaryHeight: return \.summaryHeight
        case .staffSpacing: return \.staffSpacing
        case .staffGap: return \.staffGap
        }
    }

    /// The parameters that change how `kind` looks, in the order the picker shows them.
    static func applicable(to kind: PaperKind) -> [PaperParameter] {
        switch kind {
        case .blank: return []
        case .ruled, .grid: return [.spacing, .lineWidth, .marginLeft, .marginTop]
        case .marginRuled: return [.spacing, .lineWidth, .marginLeft, .marginTop]
        case .dot: return [.spacing, .dotRadius, .marginLeft, .marginTop]
        case .isoDot: return [.spacing, .dotRadius]
        case .isoGrid: return [.spacing, .lineWidth]
        case .cornell: return [.spacing, .lineWidth, .cueWidth, .summaryHeight]
        case .staff: return [.staffSpacing, .staffGap, .lineWidth]
        }
    }
}

/// Page backgrounds the picker offers as presets; any colour can still be chosen.
enum PaperBackground: CaseIterable, Identifiable {
    case white, cream, dark

    var id: Self { self }

    var title: String {
        switch self {
        case .white: return "White"
        case .cream: return "Cream"
        case .dark: return "Dark"
        }
    }

    var color: InkVault.Color {
        switch self {
        case .white: return .white
        case .cream: return Paper.cream
        case .dark: return Paper.darkBackground
        }
    }
}

/// The paper being edited in the picker: a kind plus its parameters, always
/// kept inside the valid ranges (`Paper.Limits`).
@MainActor
@Observable
final class PaperDraft {
    /// Line colour used on the dark background preset.
    static let darkLineColor = InkVault.Color(r: 0x4A, g: 0x4F, b: 0x5C)

    private(set) var paper: Paper

    init(paper: Paper) { self.paper = paper.validated() }

    var kind: PaperKind { paper.kind }
    var parameters: [PaperParameter] { PaperParameter.applicable(to: paper.kind) }
    /// Whether the line / dot colour applies to this kind.
    var hasLineColor: Bool { paper.kind != .blank }
    /// Whether the margin colour applies to this kind.
    var hasMarginColor: Bool { paper.kind.supportsMargins && (paper.marginLeft > 0 || paper.marginTop > 0) }

    /// Whether `color` is one the app itself chose (a kind's or the dark
    /// preset's line colour), as opposed to one the user picked.
    private static func isStock(_ color: InkVault.Color) -> Bool {
        color == darkLineColor || PaperKind.allCases.contains { Paper.template($0).lineColor == color }
    }

    /// Switches to `kind` with that kind's own defaults, keeping the page
    /// background and a line colour the user picked.
    func select(_ kind: PaperKind) {
        guard kind != paper.kind else { return }
        var next = Paper.template(kind)
        next.background = paper.background
        if !Self.isStock(paper.lineColor) {
            next.lineColor = paper.lineColor
        } else if background == .dark {
            next.lineColor = Self.darkLineColor
        }
        paper = next.validated()
    }

    func value(of parameter: PaperParameter) -> Double { paper[keyPath: parameter.keyPath] }

    /// Sets a parameter, clamped to its range.
    func set(_ parameter: PaperParameter, to value: Double) {
        var next = paper
        next[keyPath: parameter.keyPath] = value
        paper = next.validated()
    }

    func setLineColor(_ color: InkVault.Color) { paper.lineColor = color }
    func setMarginColor(_ color: InkVault.Color) { paper.marginColor = color }
    func setBackgroundColor(_ color: InkVault.Color) { paper.background = color }

    /// The preset matching the current background, if any.
    var background: PaperBackground? { PaperBackground.allCases.first { $0.color == paper.background } }

    /// Picks a background preset; a stock line colour follows to the preset's.
    func select(_ preset: PaperBackground) {
        let stock = Self.isStock(paper.lineColor)
        paper.background = preset.color
        if stock { paper.lineColor = preset == .dark ? Self.darkLineColor : Paper.template(paper.kind).lineColor }
    }

    /// Back to the kind's defaults on the same background.
    func reset() {
        var next = Paper.template(paper.kind)
        next.background = paper.background
        if background == .dark { next.lineColor = Self.darkLineColor }
        paper = next.validated()
    }
}

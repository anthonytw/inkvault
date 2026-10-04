import Foundation
import InkRender
import InkVault
import PencilKit
import UIKit

// PencilKit ⇄ format conversion (format.md §5.6). Everything here works on
// iPadOS 26; nothing uses the iPadOS 27 additions (stroke ids, substroke).
//
// Carried exactly: every control point's location, time offset, size,
// opacity, force, azimuth and altitude; the ink type (except `reed`, below);
// the colour as 8-bit RGBA; the transform.
// Not representable in the format, so approximated:
// - `Ink.width`: PencilKit strokes have no nominal width; a new stroke takes
//   the tool's width when the tool still matches, else its widest point.
// - The path's `creationDate`, `randomSeed` (texture grain of pencil, crayon,
//   watercolor) and the per-point `secondaryScale`/`threshold`/`lateralJitter`:
//   rebuilt as fixed or derived values on load.
// - `mask` (the pixel eraser): each visible `maskedPathRange` becomes its own
//   stroke trimmed with `BSpline.substroke`, so cut ends are round caps rather
//   than the eraser's outline.
// - `reed` (iPadOS 26) has no format tool; it is stored as `fountainPen`.

extension InkTool {
    /// The PencilKit ink for this tool.
    var pkInkType: PKInk.InkType {
        switch self {
        case .pen: return .pen
        case .pencil: return .pencil
        case .marker: return .marker
        case .monoline: return .monoline
        case .fountainPen: return .fountainPen
        case .watercolor: return .watercolor
        case .crayon: return .crayon
        }
    }

    /// The format tool for a PencilKit ink.
    init(_ type: PKInk.InkType) {
        switch type {
        case .pen: self = .pen
        case .pencil: self = .pencil
        case .marker: self = .marker
        case .monoline: self = .monoline
        case .fountainPen: self = .fountainPen
        case .watercolor: self = .watercolor
        case .crayon: self = .crayon
        case .reed: self = .fountainPen
        @unknown default: self = .pen
        }
    }
}

extension InkVault.Color {
    /// The colour as sRGB `UIColor`.
    var uiColor: UIColor {
        UIColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: CGFloat(a) / 255)
    }

    /// The nearest 8-bit sRGB colour (wide-gamut components are clamped).
    init(_ color: UIColor) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        if !color.getRed(&r, green: &g, blue: &b, alpha: &a) {
            var white: CGFloat = 0
            if color.getWhite(&white, alpha: &a) { r = white; g = white; b = white } else { a = 1 }
        }
        func byte(_ v: CGFloat) -> UInt8 { UInt8((min(max(Double(v), 0), 1) * 255).rounded()) }
        self.init(r: byte(r), g: byte(g), b: byte(b), a: byte(a))
    }
}

extension Transform {
    init(_ t: CGAffineTransform) {
        self.init(a: Double(t.a), b: Double(t.b), c: Double(t.c), d: Double(t.d), tx: Double(t.tx), ty: Double(t.ty))
    }

    var cgAffineTransform: CGAffineTransform {
        CGAffineTransform(a: CGFloat(a), b: CGFloat(b), c: CGFloat(c), d: CGFloat(d), tx: CGFloat(tx), ty: CGFloat(ty))
    }
}

extension StrokePoint {
    init(_ p: PKStrokePoint) {
        self.init(x: Double(p.location.x), y: Double(p.location.y), t: p.timeOffset,
                  w: Double(p.size.width), h: Double(p.size.height), o: Double(p.opacity),
                  f: Double(p.force), az: Double(p.azimuth), al: Double(p.altitude))
    }

    var pkStrokePoint: PKStrokePoint {
        PKStrokePoint(location: CGPoint(x: x, y: y), timeOffset: t, size: CGSize(width: w, height: h),
                      opacity: CGFloat(o), force: CGFloat(f), azimuth: CGFloat(az), altitude: CGFloat(al))
    }
}

enum StrokeConversion {
    /// Creation date given to every path built from a stored stroke (the
    /// format does not keep one).
    static let loadedCreationDate = Date(timeIntervalSinceReferenceDate: 0)

    /// The PencilKit stroke for a stored stroke. Its texture seed is derived
    /// from the stroke id, so a textured stroke looks the same on every load.
    static func pkStroke(_ stroke: Stroke) -> PKStroke {
        let path = PKStrokePath(controlPoints: stroke.points.map(\.pkStrokePoint), creationDate: loadedCreationDate)
        let ink = PKInk(stroke.ink.tool.pkInkType, color: stroke.ink.color.uiColor)
        let transform = (stroke.transform ?? .identity).cgAffineTransform
        return PKStroke(ink: ink, path: path, transform: transform, mask: nil, randomSeed: seed(for: stroke.id))
    }

    /// A stable 32-bit seed from a stroke id.
    static func seed(for id: UUID) -> UInt32 {
        let u = id.uuid
        return UInt32(u.0) << 24 | UInt32(u.1) << 16 | UInt32(u.2) << 8 | UInt32(u.3)
    }

    /// The control points of a PencilKit path.
    static func points(of path: PKStrokePath) -> [StrokePoint] {
        path.map(StrokePoint.init)
    }

    /// The format strokes a PencilKit stroke stands for: one for an unmasked
    /// stroke, one per visible range of a masked (partly erased) one, none
    /// when the mask hides it entirely. Ids are fresh; the caller assigns
    /// the real ones.
    ///
    /// - Parameter nominalWidth: `Ink.width` to record; nil takes the widest
    ///   control point.
    static func strokes(from pk: PKStroke, nominalWidth: Double? = nil) -> [Stroke] {
        let all = points(of: pk.path)
        let transform = Transform(pk.transform)
        let width = nominalWidth ?? all.map(\.w).max() ?? 0
        let ink = Ink(tool: InkTool(pk.ink.inkType), color: InkVault.Color(pk.ink.color), width: width)
        let pieces: [[StrokePoint]]
        if pk.mask == nil {
            pieces = [all]
        } else {
            pieces = pk.maskedPathRanges.map {
                BSpline.substroke(of: all, lower: Double($0.lowerBound), upper: Double($0.upperBound))
            }
        }
        return pieces.filter { !$0.isEmpty }.map {
            Stroke(ink: ink, points: $0, transform: transform.isIdentity ? nil : transform)
        }
    }
}

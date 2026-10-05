import Foundation
import InkVault
import PencilKit
import UIKit

/// The app's object (stroke) eraser, used instead of PencilKit's when the
/// tool picker's eraser is in object mode: PencilKit's `.vector` eraser has
/// no size, this one has `ObjectEraserSize` presets.
///
/// While it is active, `PageCanvasHost` turns PencilKit's drawing gesture off
/// and this controller's gesture takes the touches: every stroke whose ink
/// the swept circle touches is removed from `canvas.drawing` at once. Setting
/// `drawing` reaches the canvas delegate like any PencilKit edit, so the
/// `StrokeLedger` turns it into the same `removeStroke` ops as PencilKit's own
/// eraser, and autosave is unchanged. One gesture is one undo step on the
/// canvas's undo manager; undo puts the strokes back (the ledger revives
/// their ids, or gives them new ids with `parent` once the removal is on
/// disk, format.md §5.2), redo removes them again.
@MainActor
final class ObjectEraserController: NSObject, UIGestureRecognizerDelegate {
    private weak var canvas: PKCanvasView?
    private weak var host: UIView?
    /// Touch-down to touch-up, with no movement threshold, so a tap erases too.
    private let press = UILongPressGestureRecognizer()
    /// Pointer or Pencil hover (Mac, iPads with hover): shows the cursor.
    private let hover = UIHoverGestureRecognizer()
    private let cursor = EraserCursorView()
    private var savedMinimumTouches: Int?

    // One gesture's state.
    private var before: PKDrawing?
    private var remaining: [PKStroke] = []
    private var shapes: [StrokeHitShape?] = []
    private var last: EraserPoint?
    private var radius = ObjectEraserSize.defaultRadius

    /// Whether the eraser takes touches (object eraser selected, note editable).
    private(set) var isActive = false

    func attach(to host: UIView, canvas: PKCanvasView) {
        self.host = host
        self.canvas = canvas
        press.minimumPressDuration = 0
        press.allowableMovement = .greatestFiniteMagnitude
        press.addTarget(self, action: #selector(pressed(_:)))
        press.delegate = self
        press.isEnabled = false
        canvas.addGestureRecognizer(press)
        hover.addTarget(self, action: #selector(hovered(_:)))
        hover.isEnabled = false
        canvas.addGestureRecognizer(hover)
        cursor.isHidden = true
        host.addSubview(cursor)
    }

    /// Turns the eraser on or off. On: PencilKit's drawing gesture is off, and
    /// with finger drawing allowed a one-finger drag erases (scrolling takes two).
    func setActive(_ active: Bool) {
        guard let canvas else { return }
        if active {
            let fingers = Self.fingersDraw(canvas)
            press.allowedTouchTypes = fingers
                ? [NSNumber(value: UITouch.TouchType.pencil.rawValue), NSNumber(value: UITouch.TouchType.direct.rawValue)]
                : [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
            if fingers, savedMinimumTouches == nil {
                savedMinimumTouches = canvas.panGestureRecognizer.minimumNumberOfTouches
                canvas.panGestureRecognizer.minimumNumberOfTouches = 2
            } else if !fingers, let saved = savedMinimumTouches {
                canvas.panGestureRecognizer.minimumNumberOfTouches = saved
                savedMinimumTouches = nil
            }
        } else {
            if let saved = savedMinimumTouches {
                canvas.panGestureRecognizer.minimumNumberOfTouches = saved
                savedMinimumTouches = nil
            }
            cursor.isHidden = true
        }
        isActive = active
        press.isEnabled = active
        hover.isEnabled = active
    }

    /// Whether finger touches draw on `canvas` (and so erase with this eraser).
    static func fingersDraw(_ canvas: PKCanvasView) -> Bool {
        switch canvas.drawingPolicy {
        case .anyInput: return true
        case .pencilOnly: return false
        default: return !UIPencilInteraction.prefersPencilOnlyDrawing
        }
    }

    // MARK: - Gestures

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // Pinch zoom and two-finger scrolling keep working.
        other === canvas?.pinchGestureRecognizer || other === canvas?.panGestureRecognizer
    }

    @objc private func pressed(_ g: UILongPressGestureRecognizer) {
        guard let canvas else { return }
        let p = pagePoint(g.location(in: canvas))
        showCursor(at: g.location(in: host))
        switch g.state {
        case .began:
            radius = ObjectEraserSize.load()
            before = canvas.drawing
            remaining = canvas.drawing.strokes
            shapes = Array(repeating: nil, count: remaining.count)
            last = p
            erase(to: p)
        case .changed:
            erase(to: p)
        case .ended, .cancelled, .failed:
            erase(to: p)
            finish()
        default:
            break
        }
    }

    @objc private func hovered(_ g: UIHoverGestureRecognizer) {
        switch g.state {
        case .began, .changed:
            radius = ObjectEraserSize.load()
            showCursor(at: g.location(in: host))
        default:
            if press.state == .possible { cursor.isHidden = true }
        }
    }

    /// Drawing (page) coordinates of a point in the canvas's bounds.
    private func pagePoint(_ p: CGPoint) -> EraserPoint {
        let z = max(canvas?.zoomScale ?? 1, 0.0001)
        return EraserPoint(x: Double(p.x / z), y: Double(p.y / z))
    }

    private func showCursor(at p: CGPoint) {
        let diameter = CGFloat(2 * radius) * (canvas?.zoomScale ?? 1)
        cursor.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        cursor.center = p
        cursor.isHidden = false
        host?.bringSubviewToFront(cursor)
    }

    private func erase(to p: EraserPoint) {
        guard let canvas, let from = last else { return }
        last = p
        var hit = IndexSet()
        for i in remaining.indices {
            if shapes[i] == nil {
                // Cheap reject on PencilKit's bounds before sampling the path.
                let b = remaining[i].renderBounds
                let r = radius
                if Double(b.maxX) < min(from.x, p.x) - r || Double(b.minX) > max(from.x, p.x) + r
                    || Double(b.maxY) < min(from.y, p.y) - r || Double(b.minY) > max(from.y, p.y) + r {
                    continue
                }
                shapes[i] = StrokeHitShape(remaining[i])
            }
            if shapes[i]?.intersects(sweepFrom: from, to: p, radius: radius) == true { hit.insert(i) }
        }
        guard !hit.isEmpty else { return }
        for i in hit.reversed() {
            remaining.remove(at: i)
            shapes.remove(at: i)
        }
        canvas.drawing = PKDrawing(strokes: remaining)
    }

    private func finish() {
        defer {
            before = nil
            remaining = []
            shapes = []
            last = nil
            if !hover.isEnabled || hover.state == .possible { cursor.isHidden = true }
        }
        guard let canvas, let before else { return }
        let after = canvas.drawing
        guard after.strokes.count != before.strokes.count else { return }
        registerUndo(restoring: DrawingBox(before), redoing: DrawingBox(after), action: "Erase")
    }

    /// One undo step that sets the drawing back to `restoring`, and its redo.
    private func registerUndo(restoring: DrawingBox, redoing: DrawingBox, action: String) {
        guard let undo = canvas?.undoManager else { return }
        undo.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated {
                target.canvas?.drawing = restoring.drawing
                target.registerUndo(restoring: redoing, redoing: restoring, action: action)
            }
        }
        undo.setActionName(action)
    }
}

/// A drawing held by the undo stack.
private final class DrawingBox: @unchecked Sendable {
    let drawing: PKDrawing
    init(_ drawing: PKDrawing) { self.drawing = drawing }
}

/// The eraser's outline at the touch point.
final class EraserCursorView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = UIColor.white.withAlphaComponent(0.25)
        layer.borderColor = UIColor.darkGray.cgColor
        layer.borderWidth = 1
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.width / 2
    }
}

extension StrokeHitShape {
    /// The ink of a canvas stroke as the eraser sees it: its path sampled
    /// every 2 pt (only the visible ranges of a pixel-erased stroke), through
    /// its transform, with the drawn half-width at each sample (`NibSize`).
    init(_ stroke: PKStroke) {
        let tool = InkTool(stroke.ink.inkType)
        let t = stroke.transform
        let scale = Double(abs(t.a * t.d - t.b * t.c)).squareRoot()
        let ranges: [ClosedRange<CGFloat>?] = stroke.mask == nil ? [nil] : stroke.maskedPathRanges.map { Optional($0) }
        var runs: [[Sample]] = []
        for range in ranges {
            var run: [Sample] = []
            for p in stroke.path.interpolatedPoints(in: range, by: .distance(2)) {
                let at = p.location.applying(t)
                let size = NibSize.formatSize(p.size, tool: tool)
                run.append(Sample(x: Double(at.x), y: Double(at.y), radius: max(size.w, size.h, 1) / 2 * scale))
            }
            runs.append(run)
        }
        self.init(runs: runs)
    }
}

enum ObjectEraser {
    /// `drawing` without the strokes an eraser of `radius` touches moving
    /// from `a` to `b` (page points), and how many were removed.
    static func erasing(_ drawing: PKDrawing, from a: EraserPoint, to b: EraserPoint,
                        radius: Double) -> (drawing: PKDrawing, removed: Int) {
        let kept = drawing.strokes.filter { !StrokeHitShape($0).intersects(sweepFrom: a, to: b, radius: radius) }
        return (PKDrawing(strokes: kept), drawing.strokes.count - kept.count)
    }
}

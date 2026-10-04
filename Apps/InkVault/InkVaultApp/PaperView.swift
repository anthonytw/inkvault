import InkRender
import InkVault
import UIKit

/// The page's paper (background colour plus ruling, grid or dots) under the
/// canvas, built from `InkRender.PaperRenderer` so it matches exports.
///
/// Rulings are vector shape layers rather than a bitmap: an infinite page can
/// be tens of thousands of points tall. Paths are built once in page points
/// and re-scaled for the zoom level.
final class PaperView: UIView {
    private let lines = CAShapeLayer()
    private let dots = CAShapeLayer()
    private var linePath = CGMutablePath()
    private var dotPath = CGMutablePath()
    private var paper: Paper?
    private var size: CGSize = .zero
    private var zoom: CGFloat = 1

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        lines.fillColor = nil
        layer.addSublayer(lines)
        layer.addSublayer(dots)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Rebuilds the ruling for `paper` on a page of `size` points.
    func configure(paper: Paper, size: CGSize) {
        guard paper != self.paper || size != self.size else { return }
        self.paper = paper
        self.size = size
        backgroundColor = paper.background.uiColor
        lines.strokeColor = paper.lineColor.uiColor.cgColor
        dots.fillColor = paper.lineColor.uiColor.cgColor
        let (l, d) = Self.paths(paper: paper, size: size)
        linePath = l
        dotPath = d
        apply()
    }

    /// Shows the paper at `zoom` (canvas points per page point).
    func setZoom(_ zoom: CGFloat) {
        guard zoom != self.zoom else { return }
        self.zoom = zoom
        apply()
    }

    private func apply() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frame = CGRect(x: 0, y: 0, width: size.width * zoom, height: size.height * zoom)
        lines.frame = bounds
        dots.frame = bounds
        var scale = CGAffineTransform(scaleX: zoom, y: zoom)
        lines.path = linePath.copy(using: &scale)
        dots.path = dotPath.copy(using: &scale)
        lines.lineWidth = PaperRenderer.ruleWidth * zoom
        CATransaction.commit()
    }

    /// Line and dot paths in page points, built band by band (PaperRenderer
    /// caps the commands per band). Ruling stops at `RenderLimits.maxExtent`,
    /// as in exports, so a corrupt or absurd page height cannot spin here.
    static func paths(paper: Paper, size: CGSize) -> (CGMutablePath, CGMutablePath) {
        let lines = CGMutablePath(), dots = CGMutablePath()
        let width = Double(size.width), height = min(Double(size.height), RenderLimits.maxExtent)
        guard width > 0, width <= RenderLimits.maxExtent, height > 0 else { return (lines, dots) }
        let band = 792.0
        var y = 0.0
        while y < height {
            let end = min(y + band, height)
            let cmds = PaperRenderer.commands(paper: paper, width: width, height: end - y, yOffset: y, yEnd: end,
                                              originY: 0, includeBackground: false)
            for c in cmds {
                switch c.primitive {
                case .line(let a, let b):
                    lines.move(to: CGPoint(x: a.x, y: a.y))
                    lines.addLine(to: CGPoint(x: b.x, y: b.y))
                case .circle(let center, let r):
                    dots.addEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
                default:
                    break
                }
            }
            y = end
        }
        return (lines, dots)
    }
}

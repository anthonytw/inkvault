import Foundation

// MARK: - Item gestures (docs/format.md §8.2)
//
// The ops for placing, moving, resizing, deleting and copying items on a
// page, built once here so the app and the CLI write the same deltas. Every
// builder takes the page as it is now (its live items) and returns the ops
// for ONE delta plus the page they leave, like `PageEdit` for page gestures.
// Items are LWW registers (§8.2.2): a move is one `setItem(frame)`, never a
// remove + add; ids live for the item's life. Tombstones are permanent, so
// an item that comes back (undo of a delete) gets a new id with `parent`.

/// The ops for one item gesture and the page they leave.
public struct ItemEdit: Hashable, Sendable {
    /// The ops, for one delta, in order.
    public var ops: [Op]
    /// The page afterwards, its items in drawing order (`Item.drawsBefore`).
    public var page: Page
    /// The ids of the items the gesture added, in the order given.
    public var added: [UUID]

    public init(ops: [Op], page: Page, added: [UUID] = []) {
        self.ops = ops; self.page = page; self.added = added
    }
}

/// Why an item gesture cannot be built.
public enum ItemEditError: Error, Hashable, Sendable {
    /// The item is not valid (format.md §8.2): the reason.
    case invalidItem(String)
    /// The page already has an item with this id.
    case duplicateID(UUID)
}

extension NoteOps {
    /// A `z` key that draws above every item of `layer` on `page`
    /// (format.md §8.2.3: compared byte-wise, like page `order`).
    public static func topZ(on page: Page, layer: ItemLayer) -> String {
        let top = page.items.filter { $0.layer == layer }.map(\.z).max { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        return PageOrder.between(top, nil)
    }

    /// Adds `items` to `page` as given (ids, `z` and all), one `addItem` each.
    /// The snapshot-only `origin` and `clocks` are dropped.
    ///
    /// - Throws: `ItemEditError.invalidItem` for an item that would not
    ///   encode, `.duplicateID` for an id already on the page or given twice.
    public static func addItems(_ items: [Item], to page: Page) throws -> ItemEdit {
        var seen = Set(page.items.map(\.id))
        var out = page
        var ops: [Op] = []
        for var item in items {
            if let why = item.validationError { throw ItemEditError.invalidItem(why) }
            guard seen.insert(item.id).inserted else { throw ItemEditError.duplicateID(item.id) }
            item.origin = nil
            item.clocks = nil
            ops.append(.addItem(page: page.id, item: item))
            out.items.append(item)
        }
        out.items.sort(by: Item.drawsBefore)
        return ItemEdit(ops: ops, page: out, added: items.map(\.id))
    }

    /// Places `item` above everything in its layer (a new `z`) on `page`.
    public static func placeOnTop(_ item: Item, on page: Page) throws -> ItemEdit {
        var placed = item
        placed.z = topZ(on: page, layer: item.layer)
        return try addItems([placed], to: page)
    }

    /// Moves or resizes the item `id` to `frame` (one `setItem(frame)`); nil
    /// when the page has no such item, the frame is not finite and positive,
    /// or nothing changes at the stored precision.
    public static func setFrame(_ id: UUID, to frame: Rect, on page: Page) -> ItemEdit? {
        guard [frame.x, frame.y, frame.w, frame.h].allSatisfy(\.isFinite), frame.hasPositiveSize else { return nil }
        return setRegister(id, .frame(frame), on: page) { $0.frame.rounded == frame.rounded }
    }

    /// Sets the rotation (degrees clockwise; 0 is stored as absent).
    public static func setRotation(_ id: UUID, to degrees: Double, on page: Page) -> ItemEdit? {
        guard degrees.isFinite else { return nil }
        var d = degrees.truncatingRemainder(dividingBy: 360)
        if d < 0 { d += 360 }
        let value: Double? = InkJSON.round3(d) == 0 || InkJSON.round3(d) == 360 ? nil : d
        return setRegister(id, .rotation(value), on: page) {
            InkJSON.round3($0.rotation ?? 0) == InkJSON.round3(value ?? 0)
        }
    }

    /// Draws the item `id` above every other item of its layer; nil when it
    /// already is the top one.
    public static func bringToFront(_ id: UUID, on page: Page) -> ItemEdit? {
        guard let item = page.items.first(where: { $0.id == id }) else { return nil }
        let others = page.items.filter { $0.layer == item.layer && $0.id != id }
        if others.allSatisfy({ Item.drawsBefore($0, item) }) { return nil }
        var rest = page
        rest.items = page.items.filter { $0.id != id }
        return setRegister(id, .z(topZ(on: rest, layer: item.layer)), on: page) { _ in false }
    }

    private static func setRegister(_ id: UUID, _ change: ItemChange, on page: Page,
                                    unchanged: (Item) -> Bool) -> ItemEdit? {
        guard let i = page.items.firstIndex(where: { $0.id == id }), !unchanged(page.items[i]) else { return nil }
        var out = page
        out.items[i].apply(change)
        out.items.sort(by: Item.drawsBefore)
        return ItemEdit(ops: [.setItem(page: page.id, itemId: id, change: change)], page: out)
    }

    /// Removes the items `ids` from `page`, one `removeItem` each (ids not on
    /// the page are skipped); nil when none is there. The blobs stay: they are
    /// collected later (format.md §8.1.6), so undo and history can use them.
    public static func removeItems(_ ids: [UUID], from page: Page) -> ItemEdit? {
        let gone = Set(ids)
        let present = page.items.filter { gone.contains($0.id) }
        guard !present.isEmpty else { return nil }
        var out = page
        out.items.removeAll { gone.contains($0.id) }
        return ItemEdit(ops: present.map { .removeItem(page: page.id, itemId: $0.id) }, page: out)
    }

    /// Puts removed items back (undo of a delete): item tombstones are
    /// permanent (format.md §8.2.2), so each comes back under a new id with
    /// `parent` naming the removed one, with every other field (`z`
    /// included, so it draws where it was) as it was.
    public static func restoreItems(_ items: [Item], to page: Page, newID: () -> UUID = UUID.init) throws -> ItemEdit {
        try addItems(items.map { NoteOps.moved($0, id: newID(), by: 0, parent: $0.id) }, to: page)
    }

    /// Copies of `items` (from this note or another) on `page`: new ids, no
    /// `parent` (a copy replaces nothing), frames shifted by `dx`, `dy`, drawn
    /// above everything in their layer in the order given. The caller copies
    /// the blobs first when they come from another note (`blobs`,
    /// `Vault.copyBlob`).
    public static func copyItems(_ items: [Item], to page: Page, dx: Double = 0, dy: Double = 0,
                                 newID: () -> UUID = UUID.init) throws -> ItemEdit {
        var target = page
        var copies: [Item] = []
        for item in items {
            var copy = NoteOps.moved(item, id: newID(), by: dy, parent: nil)
            copy.frame.x += dx
            copy.rec = nil   // the copy was not placed during that recording
            copy.z = topZ(on: target, layer: copy.layer)
            target.items.append(copy)
            copies.append(copy)
        }
        return try addItems(copies, to: page)
    }

    /// The blobs `items` reference, each once (to copy into another note
    /// before the delta that adds the copies).
    public static func blobs(of items: [Item]) -> [BlobRef] {
        var seen: Set<String> = []
        return items.compactMap(\.blob).filter { seen.insert($0.sha256).inserted }
    }
}

extension Rect {
    /// The rect at the stored precision (format.md §5.6: 3 decimals).
    var rounded: Rect { Rect(x: InkJSON.round3(x), y: InkJSON.round3(y), w: InkJSON.round3(w), h: InkJSON.round3(h)) }
}

// MARK: - Item frames on the page

/// Geometry of placed items on a page (format.md §8.5.1): hit testing,
/// bounds, moving and resizing a rotated frame. Page coordinates, y down;
/// rotation is clockwise about the frame's centre.
public enum ItemFrames {
    /// A point in page coordinates.
    public struct Point: Hashable, Sendable {
        public var x: Double, y: Double
        public init(x: Double, y: Double) { self.x = x; self.y = y }
    }

    /// cos and sin of `degrees`, exact for multiples of 90.
    static func trig(_ degrees: Double) -> (cos: Double, sin: Double) {
        let r = (degrees.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        switch r {
        case 0: return (1, 0)
        case 90: return (0, 1)
        case 180: return (-1, 0)
        case 270: return (0, -1)
        default: return (cos(r * .pi / 180), sin(r * .pi / 180))
        }
    }

    /// `p` turned by `degrees` (clockwise on the y-down page) about `c`.
    static func rotate(_ p: Point, about c: Point, degrees: Double) -> Point {
        let (cs, sn) = trig(degrees)
        let dx = p.x - c.x, dy = p.y - c.y
        return Point(x: c.x + cs * dx - sn * dy, y: c.y + sn * dx + cs * dy)
    }

    static func centre(_ f: Rect) -> Point { Point(x: f.x + f.w / 2, y: f.y + f.h / 2) }

    /// The frame's corners after rotation: top-left, top-right, bottom-right,
    /// bottom-left of the unrotated frame.
    public static func corners(_ frame: Rect, rotation: Double?) -> [Point] {
        let c = centre(frame), d = rotation ?? 0
        return [Point(x: frame.x, y: frame.y), Point(x: frame.x + frame.w, y: frame.y),
                Point(x: frame.x + frame.w, y: frame.y + frame.h), Point(x: frame.x, y: frame.y + frame.h)]
            .map { rotate($0, about: c, degrees: d) }
    }

    /// The axis-aligned bounds of the rotated frame.
    public static func bounds(_ frame: Rect, rotation: Double?) -> Rect {
        let ps = corners(frame, rotation: rotation)
        let xs = ps.map(\.x), ys = ps.map(\.y)
        let x0 = xs.min() ?? frame.x, y0 = ys.min() ?? frame.y
        return Rect(x: x0, y: y0, w: (xs.max() ?? x0) - x0, h: (ys.max() ?? y0) - y0)
    }

    /// Whether `p` lies in the rotated frame grown by `slop` on each side.
    public static func contains(_ frame: Rect, rotation: Double?, _ p: Point, slop: Double = 0) -> Bool {
        let local = rotate(p, about: centre(frame), degrees: -(rotation ?? 0))
        return local.x >= frame.x - slop && local.x <= frame.x + frame.w + slop
            && local.y >= frame.y - slop && local.y <= frame.y + frame.h + slop
    }

    /// The item drawn topmost at `p`, or nil. Content items win over
    /// background items (PDF pages fill the page; selecting one by every tap
    /// would hide the image or text on it); `includeBackground: false` never
    /// returns a background item.
    public static func item(at p: Point, in items: [Item], slop: Double = 0, includeBackground: Bool = true) -> Item? {
        let hits = items.sorted(by: Item.drawsBefore).reversed().filter {
            contains($0.frame, rotation: $0.rotation, p, slop: slop)
        }
        return hits.first { !$0.layer.isBackground } ?? (includeBackground ? hits.first : nil)
    }

    /// The frame moved by `dx`, `dy`.
    public static func moved(_ frame: Rect, dx: Double, dy: Double) -> Rect {
        Rect(x: frame.x + dx, y: frame.y + dy, w: frame.w, h: frame.h)
    }

    /// A corner of the frame, for resizing (indices as in `corners`).
    public enum Corner: Int, CaseIterable, Sendable {
        case topLeft, topRight, bottomRight, bottomLeft

        /// The corner across the frame (it stays put while this one is dragged).
        var opposite: Corner { Corner(rawValue: (rawValue + 2) % 4) ?? .topLeft }
        /// Unit signs of this corner relative to the centre, in frame axes.
        var signs: (x: Double, y: Double) {
            switch self {
            case .topLeft: return (-1, -1)
            case .topRight: return (1, -1)
            case .bottomRight: return (1, 1)
            case .bottomLeft: return (-1, 1)
            }
        }
    }

    /// The frame after dragging `corner` by `dx`, `dy` (page coordinates):
    /// the opposite corner stays where it is on the page, the rotation is
    /// kept, and the size is at least `minSize` on each side. With
    /// `keepAspect` (images, PDF pages) the size keeps the frame's
    /// proportions, following the larger of the two changes.
    public static func resized(_ frame: Rect, rotation: Double?, corner: Corner, dx: Double, dy: Double,
                               keepAspect: Bool, minSize: Double = 8) -> Rect {
        let d = rotation ?? 0
        // The drag in the frame's own axes.
        let local = rotate(Point(x: dx, y: dy), about: Point(x: 0, y: 0), degrees: -d)
        let s = corner.signs
        var w = frame.w + s.x * local.x
        var h = frame.h + s.y * local.y
        if keepAspect, frame.w > 0, frame.h > 0 {
            let k = max(w / frame.w, h / frame.h)
            w = frame.w * k
            h = frame.h * k
        }
        let floor = max(minSize, 0)
        if keepAspect, frame.w > 0, frame.h > 0, w < floor || h < floor {
            let k = max(floor / frame.w, floor / frame.h)
            w = frame.w * k; h = frame.h * k
        } else {
            w = max(w, floor); h = max(h, floor)
        }
        guard w.isFinite, h.isFinite else { return frame }
        // The fixed corner on the page, and the new centre from it.
        let fixed = corners(frame, rotation: d)[corner.opposite.rawValue]
        let o = corner.opposite.signs
        let half = rotate(Point(x: -o.x * w / 2, y: -o.y * h / 2), about: Point(x: 0, y: 0), degrees: d)
        let c = Point(x: fixed.x + half.x, y: fixed.y + half.y)
        return Rect(x: c.x - w / 2, y: c.y - h / 2, w: w, h: h)
    }
}

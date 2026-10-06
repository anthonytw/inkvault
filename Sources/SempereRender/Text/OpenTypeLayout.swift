import Foundation

/// The subset of OpenType layout the CLI's shaper uses (docs/attachments.md
/// §6): GSUB single (1) and ligature (4) substitution, GPOS mark-to-base (4),
/// mark-to-ligature (5) and mark-to-mark (6), each also inside extension
/// lookups (GSUB 7, GPOS 9); GDEF glyph classes for lookup flags.
/// Everything is bounds-checked; lookups that are not understood are skipped.
struct OpenTypeLayout: Sendable {
    let b: FontBytes
    let gsub: Int?
    let gpos: Int?
    /// GDEF glyph class definition table offset (1 base, 2 ligature, 3 mark, 4 component).
    let glyphClasses: Int?
    /// GDEF mark attachment classes.
    let markClasses: Int?

    init(_ font: OpenTypeFont) {
        b = font.bytes
        gsub = font.tables["GSUB"]?.lowerBound
        gpos = font.tables["GPOS"]?.lowerBound
        var gc: Int?, mc: Int?
        if let gdef = font.tables["GDEF"]?.lowerBound {
            if let o = try? b.u16(gdef + 4), o != 0 { gc = gdef + o }
            if let o = try? b.u16(gdef + 10), o != 0 { mc = gdef + o }
        }
        glyphClasses = gc
        markClasses = mc
    }

    func glyphClass(_ g: Int) -> Int { glyphClasses.map { classDef($0, g) } ?? 0 }

    // MARK: Common tables

    /// Coverage index of `g`, or nil.
    func coverage(_ o: Int, _ g: Int) -> Int? {
        guard let format = try? b.u16(o) else { return nil }
        if format == 1 {
            guard let n = try? b.u16(o + 2) else { return nil }
            var lo = 0, hi = n - 1
            while lo <= hi {
                let mid = (lo + hi) / 2
                guard let v = try? b.u16(o + 4 + 2 * mid) else { return nil }
                if v == g { return mid } else if v < g { lo = mid + 1 } else { hi = mid - 1 }
            }
        } else if format == 2 {
            guard let n = try? b.u16(o + 2) else { return nil }
            var lo = 0, hi = n - 1
            while lo <= hi {
                let mid = (lo + hi) / 2
                let r = o + 4 + 6 * mid
                guard let s = try? b.u16(r), let e = try? b.u16(r + 2), let i = try? b.u16(r + 4) else { return nil }
                if g < s { hi = mid - 1 } else if g > e { lo = mid + 1 } else { return i + g - s }
            }
        }
        return nil
    }

    /// Class of `g` in a ClassDef table (0 when absent).
    func classDef(_ o: Int, _ g: Int) -> Int {
        guard let format = try? b.u16(o) else { return 0 }
        if format == 1 {
            guard let start = try? b.u16(o + 2), let n = try? b.u16(o + 4), g >= start, g < start + n else { return 0 }
            return (try? b.u16(o + 6 + 2 * (g - start))) ?? 0
        }
        if format == 2, let n = try? b.u16(o + 2) {
            var lo = 0, hi = n - 1
            while lo <= hi {
                let mid = (lo + hi) / 2
                let r = o + 4 + 6 * mid
                guard let s = try? b.u16(r), let e = try? b.u16(r + 2) else { return 0 }
                if g < s { hi = mid - 1 } else if g > e { lo = mid + 1 } else { return (try? b.u16(r + 4)) ?? 0 }
            }
        }
        return 0
    }

    /// Lookup indices of `features` for `script` (falling back to `DFLT`,
    /// then `latn`), default language system, in lookup-list order.
    func lookups(_ table: Int?, script: String, features: Set<String>) -> [(index: Int, feature: String)] {
        guard let t = table, let scriptList = try? b.u16(t + 4), let featureList = try? b.u16(t + 6) else { return [] }
        let sl = t + scriptList, fl = t + featureList
        guard let count = try? b.u16(sl) else { return [] }
        var langSys: Int?
        for wanted in [script, "DFLT", "latn"] where langSys == nil {
            for i in 0..<min(count, 256) {
                guard let tag = try? b.tag(sl + 2 + 6 * i), tag == wanted,
                      let so = try? b.u16(sl + 2 + 6 * i + 4), let d = try? b.u16(sl + so), d != 0 else { continue }
                langSys = sl + so + d
                break
            }
        }
        guard let ls = langSys, let n = try? b.u16(ls + 4) else { return [] }
        var indices: [Int] = []
        if let req = try? b.u16(ls + 2), req != 0xFFFF { indices.append(req) }
        for i in 0..<min(n, 512) { if let f = try? b.u16(ls + 6 + 2 * i) { indices.append(f) } }
        var out: [(Int, String)] = []
        guard let fcount = try? b.u16(fl) else { return [] }
        for f in indices where f < fcount {
            guard let tag = try? b.tag(fl + 2 + 6 * f), features.contains(tag),
                  let fo = try? b.u16(fl + 2 + 6 * f + 4), let ln = try? b.u16(fl + fo + 2) else { continue }
            for j in 0..<min(ln, 512) { if let l = try? b.u16(fl + fo + 4 + 2 * j) { out.append((l, tag)) } }
        }
        return out.sorted { $0.0 < $1.0 }
    }

    /// A lookup's type, flag, mark filtering set and subtable offsets (extension subtables unwrapped).
    func lookup(_ table: Int, _ index: Int) -> (type: Int, flag: Int, filter: Int?, subtables: [Int])? {
        guard let ll = try? b.u16(table + 8), let n = try? b.u16(table + ll), index < n,
              let lo = try? b.u16(table + ll + 2 + 2 * index) else { return nil }
        let l = table + ll + lo
        guard var type = try? b.u16(l), let flag = try? b.u16(l + 2), let count = try? b.u16(l + 4) else { return nil }
        var subs: [Int] = []
        let isGSUB = table == gsub
        for i in 0..<min(count, 256) {
            guard let so = try? b.u16(l + 6 + 2 * i) else { continue }
            var s = l + so
            if (isGSUB && type == 7) || (!isGSUB && type == 9) {
                guard let t = try? b.u16(s + 2), let off = try? b.u32(s + 4) else { continue }
                type = t
                s += off
            }
            subs.append(s)
        }
        let filter = flag & 0x10 != 0 ? (try? b.u16(l + 6 + 2 * count)) : nil
        return (type, flag, filter, subs)
    }

    /// True when lookup flags say glyph `g` is skipped.
    func ignores(_ flag: Int, _ g: Int) -> Bool {
        let c = glyphClass(g)
        if flag & 2 != 0 && c == 1 { return true }
        if flag & 4 != 0 && c == 2 { return true }
        if flag & 8 != 0 && c == 3 { return true }
        if c == 3, flag & 0xFF00 != 0, let mc = markClasses, classDef(mc, g) != flag >> 8 { return true }
        return false
    }

    // MARK: GSUB

    /// Single substitution of `g` by lookup `index`, or nil.
    func substitute(_ index: Int, _ g: Int) -> Int? {
        guard let t = gsub, let l = lookup(t, index), l.type == 1 else { return nil }
        for s in l.subtables {
            guard let format = try? b.u16(s), let cov = try? b.u16(s + 2), let i = coverage(s + cov, g) else { continue }
            if format == 1, let delta = try? b.i16(s + 4) { return (g + delta) & 0xFFFF }
            if format == 2, let n = try? b.u16(s + 4), i < n, let r = try? b.u16(s + 6 + 2 * i) { return r }
        }
        return nil
    }

    /// The longest ligature of lookup `index` starting at `glyphs[i]`:
    /// the ligature glyph and the positions it consumes, or nil.
    func ligature(_ index: Int, _ glyphs: [Int], at i: Int) -> (glyph: Int, positions: [Int])? {
        guard let t = gsub, let l = lookup(t, index), l.type == 4, i < glyphs.count else { return nil }
        for s in l.subtables {
            guard let cov = try? b.u16(s + 2), let ci = coverage(s + cov, glyphs[i]),
                  let setCount = try? b.u16(s + 4), ci < setCount, let so = try? b.u16(s + 6 + 2 * ci) else { continue }
            let set = s + so
            guard let n = try? b.u16(set) else { continue }
            for k in 0..<min(n, 1024) {
                guard let lo = try? b.u16(set + 2 + 2 * k), let lig = try? b.u16(set + lo),
                      let comps = try? b.u16(set + lo + 2), comps >= 1, comps <= 32 else { continue }
                var positions = [i]
                var j = i + 1
                var ok = true
                for c in 1..<comps {
                    while j < glyphs.count, ignores(l.flag, glyphs[j]) { j += 1 }
                    guard j < glyphs.count, let want = try? b.u16(set + lo + 4 + 2 * (c - 1)), want == glyphs[j] else {
                        ok = false; break
                    }
                    positions.append(j)
                    j += 1
                }
                if ok { return (lig, positions) }
            }
        }
        return nil
    }

    // MARK: GPOS

    func anchor(_ o: Int) -> Point? {
        guard let x = try? b.i16(o + 2), let y = try? b.i16(o + 4) else { return nil }
        return Point(x: Double(x), y: Double(y))
    }

    /// For mark glyph `mark` on base `base` (types 4, 5 or 6 per `type`):
    /// the offset (base anchor − mark anchor), or nil when the lookup does not apply.
    func attach(_ index: Int, mark: Int, base: Int, component: Int = 0) -> (type: Int, offset: Point)? {
        guard let t = gpos, let l = lookup(t, index), [4, 5, 6].contains(l.type) else { return nil }
        for s in l.subtables {
            guard let mc = try? b.u16(s + 2), let bc = try? b.u16(s + 4), let classes = try? b.u16(s + 6),
                  let ma = try? b.u16(s + 8), let ba = try? b.u16(s + 10),
                  let mi = coverage(s + mc, mark), let bi = coverage(s + bc, base) else { continue }
            let markArray = s + ma
            guard let markClass = try? b.u16(markArray + 2 + 4 * mi), markClass < classes,
                  let mao = try? b.u16(markArray + 2 + 4 * mi + 2), let markAnchor = anchor(markArray + mao) else { continue }
            var baseAnchorOffset: Int?
            if l.type == 5 {
                guard let lo = try? b.u16(s + ba + 2 + 2 * bi) else { continue }
                let att = s + ba + lo
                guard let comps = try? b.u16(att), comps > 0 else { continue }
                let c = min(component, comps - 1)
                if let ao = try? b.u16(att + 2 + 2 * (c * classes + markClass)), ao != 0 { baseAnchorOffset = att + ao }
            } else {
                let rec = s + ba + 2 + 2 * (bi * classes + markClass)
                if let ao = try? b.u16(rec), ao != 0 { baseAnchorOffset = s + ba + ao }
            }
            guard let bo = baseAnchorOffset, let baseAnchor = anchor(bo) else { continue }
            return (l.type, Point(x: baseAnchor.x - markAnchor.x, y: baseAnchor.y - markAnchor.y))
        }
        return nil
    }
}

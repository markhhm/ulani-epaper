import Foundation

/// Pillow's scan conversion of the shapes the pages draw (src/libImaging/Draw.c in Pillow 12.3,
/// which the Python reference draws with): every shape is a list of horizontal runs, each
/// `(y, x0, x1)` with both ends inclusive, handed to `span` in Pillow's order. The page clips
/// them to the canvas, as Pillow's `hline` does.
///
/// Follows the C code operation for operation (integer steps, and Float or Double where it uses
/// them), so the shapes are Pillow's pixel for pixel: Differential/page-expectations.json
/// checks every primitive at every size the pages use and over a sweep around them.
enum Raster {
    typealias Span = (_ y: Int, _ x0: Int, _ x1: Int) -> Void

    // MARK: Ellipses (ImagingDrawEllipse)

    /// The ellipse inscribed in the inclusive box: filled, or its outline `width` px thick.
    static func ellipse(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, fill: Bool, width: Int, span: Span) {
        let a = x1 - x0, b = y1 - y0
        guard a >= 0, b >= 0 else { return }
        var spans = EllipseSpans(a: a, b: b, width: fill ? a + b : width)
        while let (l, y, r) = spans.next() {
            span(y0 + (y + b) / 2, x0 + (l + a) / 2, x0 + (r + a) / 2)
        }
    }

    /// A filled pie slice from `start` to `end` degrees, clockwise from 3 o'clock
    /// (ImagingDrawPieslice with fill).
    static func pieslice(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, start: Float, end: Float, span: Span) {
        var (al, ar) = (start, end)
        normalizeAngles(&al, &ar)
        if al + 360 == ar {
            ellipse(x0, y0, x1, y1, fill: true, width: 0, span: span)
            return
        }
        if al == ar { return }
        let a = x1 - x0, b = y1 - y0
        guard a >= 0, b >= 0 else { return }
        clipped(x0, y0, a, b, EllipseSpans(a: a, b: b, width: a + b), pieClip(a, b, al, ar), span: span)
    }

    /// An arc `width` px thick from `start` to `end` degrees (ImagingDrawArc).
    static func arc(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, start: Float, end: Float, width: Int,
                    span: Span) {
        var (al, ar) = (start, end)
        normalizeAngles(&al, &ar)
        if al + 360 == ar {
            ellipse(x0, y0, x1, y1, fill: false, width: width, span: span)
            return
        }
        if al == ar { return }
        let a = x1 - x0, b = y1 - y0
        guard a >= 0, b >= 0 else { return }
        clipped(x0, y0, a, b, EllipseSpans(a: a, b: b, width: width), arcClip(a, b, al, ar), span: span)
    }

    /// clipEllipseNew: each run of the ellipse cut by the clipping tree.
    private static func clipped(_ x0: Int, _ y0: Int, _ a: Int, _ b: Int, _ spans: EllipseSpans, _ root: ClipNode?,
                                span: Span) {
        var spans = spans
        while let (l, y, r) = spans.next() {
            let events = clip(root, l, y, r)
            for i in stride(from: 0, to: events.count - 1, by: 2) {
                span(y0 + (y + b) / 2, x0 + (events[i].x + a) / 2, x0 + (events[i + 1].x + a) / 2)
            }
        }
    }

    /// Resulting angles satisfy 0 <= al < 360, al <= ar <= al + 360 (normalize_angles, in
    /// C float arithmetic).
    static func normalizeAngles(_ al: inout Float, _ ar: inout Float) {
        if ar - al >= 360 {
            al = 0
            ar = 360
        } else {
            al = Float(fmod(al < 0 ? 360 - fmod(Double(-al), 360) : Double(al), 360))
            ar = Float(Double(al) + fmod(ar < al ? 360 - fmod(Double(al - ar), 360) : Double(ar - al), 360))
        }
    }

    /// One quarter of an ellipse with semi-axes a/2 and b/2, traced with Bresenham steps on the
    /// grid {(2x + a % 2, 2y + b % 2)} from (a, b % 2) to (a % 2, b) (quarter_state).
    struct Quarter {
        private var a2 = 0, b2 = 0, a2b2 = 0
        private var cx = 0, cy = 0, ex = 0, ey = 0
        private(set) var finished: Bool

        init(a: Int, b: Int) {
            finished = a < 0 || b < 0
            if finished { return }
            cx = a
            cy = b % 2
            ex = a % 2
            ey = b
            a2 = a * a
            b2 = b * b
            a2b2 = a2 * b2
        }

        /// How far the point is off the curve (the ellipse equation with the point put in).
        private func delta(_ x: Int, _ y: Int) -> Int { abs(a2 * y * y + b2 * x * x - a2b2) }

        /// The current point, then a step to the next one; nil once past the end.
        mutating func next() -> (x: Int, y: Int)? {
            if finished { return nil }
            let point = (x: cx, y: cy)
            if cx == ex && cy == ey {
                finished = true
            } else {
                var nx = cx, ny = cy + 2
                var ndelta = delta(nx, ny)
                if nx > 1 {
                    var candidate = delta(cx - 2, cy + 2)
                    if ndelta > candidate {
                        (nx, ny, ndelta) = (cx - 2, cy + 2, candidate)
                    }
                    candidate = delta(cx - 2, cy)
                    if ndelta > candidate {
                        (nx, ny) = (cx - 2, cy)
                    }
                }
                (cx, cy) = (nx, ny)
            }
            return point
        }
    }

    /// The runs of a whole ellipse of the given thickness, between an outer and an inner
    /// quarter, on the doubled grid (ellipse_state).
    struct EllipseSpans {
        private var outer: Quarter
        private var inner = Quarter(a: -1, b: -1)
        private var py = 0, pl = 0, pr = 0
        private var buffer: [(l: Int, y: Int, r: Int)] = []
        private var finished = false
        private let leftmost: Int

        init(a: Int, b: Int, width: Int) {
            leftmost = a % 2
            outer = Quarter(a: a, b: b)
            if width < 1 {
                finished = true
            } else if let (x, y) = outer.next() {
                (pr, py) = (x, y)
                inner = Quarter(a: a - 2 * (width - 1), b: b - 2 * (width - 1))
                pl = leftmost
            } else {
                finished = true
            }
        }

        mutating func next() -> (l: Int, y: Int, r: Int)? {
            if buffer.isEmpty {
                if finished { return nil }
                let y = py, r = pr
                var l = pl
                var point: (x: Int, y: Int)?
                repeat { point = outer.next() } while point.map { $0.y <= y } ?? false
                if let point {
                    (pr, py) = (point.x, point.y)
                } else {
                    finished = true
                }
                point = inner.next()
                while let p = point, p.y <= y {
                    l = p.x
                    point = inner.next()
                }
                pl = point?.x ?? leftmost
                if (l > 0 || l < r) && y > 0 { buffer.append((l == 0 ? 2 : l, y, r)) }
                if y > 0 { buffer.append((-r, y, -l)) }
                if l > 0 || l < r { buffer.append((l == 0 ? 2 : l, -y, r)) }
                buffer.append((-r, -y, -l))
            }
            return buffer.removeLast()
        }
    }

    // MARK: Clipping trees (clip_node)

    /// Half-planes `a·x + b·y + c >= 0` combined by intersection and union.
    indirect enum ClipNode {
        case and(ClipNode, ClipNode)
        case or(ClipNode, ClipNode)
        case halfPlane(a: Double, b: Double, c: Double)

        /// Mirrored in the line y = x (clip_tree_transpose).
        var transposed: ClipNode {
            switch self {
            case .and(let l, let r): .and(l.transposed, r.transposed)
            case .or(let l, let r): .or(l.transposed, r.transposed)
            case .halfPlane(let a, let b, let c): .halfPlane(a: b, b: a, c: c)
            }
        }

        static func combine(_ intersect: Bool, _ l: ClipNode, _ r: ClipNode) -> ClipNode {
            intersect ? .and(l, r) : .or(l, r)
        }
    }

    /// The run l...r on row y clipped by `node`: sorted opening (+1) and closing (-1) ends of
    /// disjoint runs (clip_tree_do_clip).
    static func clip(_ node: ClipNode?, _ x0: Int, _ y: Int, _ x1: Int) -> [(x: Int, type: Int)] {
        guard let node else { return [(x0, 1), (x1, -1)] }
        switch node {
        case .halfPlane(let a, let b, let c):
            let eps = 1e-9
            var (x0, x1) = (x0, x1)
            let by = b * Double(y)
            if abs(a) < eps {
                if by + c < -eps { (x0, x1) = (1, 0) }
            } else {
                let ix = -(by + c) / a  // where the boundary crosses the row
                if a * Double(x0) + by + c < eps { x0 = lround(fmax(Double(x0), ix)) }
                if a * Double(x1) + by + c < eps { x1 = lround(fmin(Double(x1), ix)) }
            }
            return x0 <= x1 ? [(x0, 1), (x1, -1)] : []
        case .and(let l, let r), .or(let l, let r):
            var intersect = false
            if case .and = node { intersect = true }
            let left = clip(l, x0, y, x1), right = clip(r, x0, y, x1)
            var out: [(x: Int, type: Int)] = []
            var i = 0, j = 0, k1 = 0, k2 = 0
            while i < left.count || j < right.count {
                let t: (x: Int, type: Int)
                if j == right.count || (i < left.count && (left[i].x < right[j].x
                                                         || (left[i].x == right[j].x && left[i].type > right[j].type))) {
                    t = left[i]
                    k1 += t.type
                    i += 1
                } else {
                    t = right[j]
                    k2 += t.type
                    j += 1
                }
                let tail = out.last?.type
                let keep = intersect
                    ? (t.type == 1 && tail != 1 && k1 > 0 && k2 > 0) || (t.type == -1 && tail == 1 && (k1 == 0 || k2 == 0))
                    : (t.type == 1 && tail != 1) || (t.type == -1 && k1 == 0 && k2 == 0)
                if keep { out.append(t) }
            }
            return out
        }
    }

    /// pie_init: the two sides of the slice, plus a half-plane against spikes under 90°.
    private static func pieClip(_ a: Int, _ b: Int, _ al: Float, _ ar: Float) -> ClipNode {
        let xl = Double(a) * cos(Double(al) * .pi / 180.0), xr = Double(a) * cos(Double(ar) * .pi / 180.0)
        let yl = Double(b) * sin(Double(al) * .pi / 180.0), yr = Double(b) * sin(Double(ar) * .pi / 180.0)
        var root = ClipNode.combine(ar - al < 180, .halfPlane(a: -yl, b: xl, c: 0), .halfPlane(a: yr, b: -xr, c: 0))
        if ar - al < 90 {
            root = .and(root, .halfPlane(a: (xl + xr) / 2.0, b: (yl + yr) / 2.0, c: 0))
        }
        return root
    }

    /// arc_init: caps square to the curve, built on the wider axis (a >= b), else transposed.
    private static func arcClip(_ a: Int, _ b: Int, _ al: Float, _ ar: Float) -> ClipNode? {
        if a < b { return arcClip(b, a, 90 - ar, 90 - al)?.transposed }
        var (al, ar) = (al, ar)
        normalizeAngles(&al, &ar)
        if ar == al + 360 { return nil }
        func radians(_ angle: Float, _ per: Double) -> Double { Double(angle) * .pi / per }
        let lc = ClipNode.halfPlane(a: Double(-a) * sin(radians(al, 180.0)), b: Double(b) * cos(radians(al, 180.0)),
                                    c: Double(a * a - b * b) * sin(radians(al, 90.0)) / 2.0)
        let rc = ClipNode.halfPlane(a: Double(a) * sin(radians(ar, 180.0)), b: Double(-b) * cos(radians(ar, 180.0)),
                                    c: Double(b * b - a * a) * sin(radians(ar, 90.0)) / 2.0)
        if fmod(al, 180) == 0 || fmod(ar, 180) == 0 {
            return .combine(ar - al < 180, lc, rc)
        }
        if (Int(al / 180) + Int(ar / 180)) % 2 == 1 {
            let bl: Double = Int(al / 180) % 2 == 0 ? 1 : -1
            let br: Double = Int(ar / 180) % 2 == 0 ? 1 : -1
            return .or(.and(.halfPlane(a: 0, b: bl, c: 0), lc), .and(.halfPlane(a: 0, b: br, c: 0), rc))
        }
        let intersect = ar - al < 180
        let side: Double = ar < 180 || ar > 540 ? 1 : -1
        return .combine(intersect, .combine(intersect, lc, rc), .halfPlane(a: 0, b: side, c: 0))
    }

    // MARK: Rectangles and lines

    /// ImagingDrawRectangle with fill: rows y0...y1 (clipped to the canvas height `rows`).
    static func filledRectangle(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, rows: Int, span: Span) {
        let (top, bottom) = y0 > y1 ? (y1, y0) : (y0, y1)
        guard top < rows, bottom >= 0 else { return }
        for y in max(top, 0)...min(bottom, rows) {
            span(y, x0, x1)
        }
    }

    /// ImagingDrawRectangle without fill: a frame `width` px thick.
    static func rectangleOutline(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, width: Int, span: Span,
                                 point: (Int, Int) -> Void) {
        let (y0, y1) = y0 > y1 ? (y1, y0) : (y0, y1)
        let width = width == 0 ? 1 : width
        for i in 0..<width {
            span(y0 + i, x0, x1)
            span(y1 - i, x0, x1)
            line(x1 - i, y0 + width, x1 - i, y1 - width + 1, point: point)
            line(x0 + i, y0 + width, x0 + i, y1 - width + 1, point: point)
        }
    }

    /// A 1 px line from (x0, y0) up to, not including, (x1, y1): Bresenham (line32).
    static func line(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, point: (Int, Int) -> Void) {
        var (x, y) = (x0, y0)
        var dx = x1 - x0, dy = y1 - y0
        let xs = dx < 0 ? -1 : 1, ys = dy < 0 ? -1 : 1
        dx = abs(dx)
        dy = abs(dy)
        if dx == 0 {
            for _ in 0..<dy {
                point(x, y)
                y += ys
            }
        } else if dy == 0 {
            for _ in 0..<dx {
                point(x, y)
                x += xs
            }
        } else if dx > dy {
            let n = dx
            dy += dy
            var e = dy - dx
            dx += dx
            for _ in 0..<n {
                point(x, y)
                if e >= 0 {
                    y += ys
                    e -= dx
                }
                e += dy
                x += xs
            }
        } else {
            let n = dy
            dx += dx
            var e = dx - dy
            dy += dy
            for _ in 0..<n {
                point(x, y)
                if e >= 0 {
                    x += xs
                    e -= dy
                }
                e += dx
                y += ys
            }
        }
    }

    /// A segment `width` (> 1) px wide, as a filled quadrilateral (ImagingDrawWideLine); a
    /// zero-length segment is one point.
    static func wideLine(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, width: Int, rows: Int, span: Span,
                         point: (Int, Int) -> Void) {
        let dx = x1 - x0, dy = y1 - y0
        if dx == 0 && dy == 0 {
            point(x0, y0)
            return
        }
        let big = hypot(Double(dx), Double(dy))
        let small = Double(width - 1) / 2.0
        let ratioMax = Double(roundUp(small)) / big
        let ratioMin = Double(roundDown(small)) / big
        let dxmin = roundDown(ratioMin * Double(dy)), dxmax = roundDown(ratioMax * Double(dy))
        let dymin = roundDown(ratioMin * Double(dx)), dymax = roundDown(ratioMax * Double(dx))
        let v = [(x0 - dxmin, y0 + dymax), (x1 - dxmin, y1 + dymax), (x1 + dxmax, y1 - dymin), (x0 + dxmax, y0 - dymin)]
        let edges = (0..<4).map { Edge(v[$0].0, v[$0].1, v[($0 + 1) % 4].0, v[($0 + 1) % 4].1) }
        polygon(edges, rows: rows, span: span)
    }

    /// ROUND_UP / ROUND_DOWN: half away from / towards zero. For a C float the positive branch
    /// adds 0.5F in float, the negative one in double (fabs returns a double).
    private static func roundUp(_ f: Double) -> Int {
        Int(f >= 0 ? (f + 0.5).rounded(.down) : -(abs(f) + 0.5).rounded(.down))
    }

    private static func roundDown(_ f: Double) -> Int {
        Int(f >= 0 ? (f - 0.5).rounded(.up) : -(abs(f) - 0.5).rounded(.up))
    }

    private static func roundUp(_ f: Float) -> Int {
        Int(f >= 0 ? Double(f + 0.5).rounded(.down) : -(Double(abs(f)) + 0.5).rounded(.down))
    }

    private static func roundDown(_ f: Float) -> Int {
        Int(f >= 0 ? Double(f - 0.5).rounded(.up) : -(Double(abs(f)) - 0.5).rounded(.up))
    }

    /// One polygon edge (Edge, add_edge).
    struct Edge {
        let x0, y0, xmin, ymin, xmax, ymax: Int
        let dx: Float

        init(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) {
            (xmin, xmax) = x0 <= x1 ? (x0, x1) : (x1, x0)
            (ymin, ymax) = y0 <= y1 ? (y0, y1) : (y1, y0)
            dx = y0 == y1 ? 0 : Float(x1 - x0) / Float(y1 - y0)
            self.x0 = x0
            self.y0 = y0
        }

        /// The edge's x on row y, in C float arithmetic.
        func x(at y: Int) -> Float { Float(y - y0) * dx + Float(x0) }
    }

    /// polygon_generic for an opaque image: horizontal edges as they are, then on every row the
    /// edges' crossings, sorted, filled pairwise.
    static func polygon(_ edges: [Edge], rows: Int, span: Span) {
        var ymin = rows - 1, ymax = 0
        var table: [Edge] = []
        for e in edges {
            ymin = min(ymin, e.ymin)
            ymax = max(ymax, e.ymax)
            if e.ymin == e.ymax {
                span(e.ymin, e.xmin, e.xmax)
                continue
            }
            table.append(e)
        }
        ymin = max(ymin, 0)
        ymax = min(ymax, rows)
        guard ymin <= ymax else { return }
        for y in ymin...ymax {
            var xx: [Float] = []
            for (i, current) in table.enumerated() where y >= current.ymin && y <= current.ymax {
                xx.append(current.x(at: y))
                if y == current.ymax && y < ymax {
                    xx.append(xx[xx.count - 1])  // needed to draw consistent polygons
                } else if (y == current.ymin || y == current.ymax) && current.dx != 0 {
                    // connect discontiguous corners
                    for other in table[..<i] {
                        if (y != other.ymin && y != other.ymax) || other.dx == 0 { continue }
                        guard xx[xx.count - 1].rounded(.toNearestOrAwayFromZero)
                                == other.x(at: y).rounded(.toNearestOrAwayFromZero) else { continue }
                        let offset = y == current.ymax ? -1 : 1
                        let adjacent = current.x(at: y + offset)
                        guard y + offset >= other.ymin && y + offset <= other.ymax else { continue }
                        let adjacentOther = other.x(at: y + offset)
                        let last = xx[xx.count - 1]
                        if last > adjacent + 1 && last > adjacentOther + 1 {
                            xx[xx.count - 1] = Float(fmax(Double(adjacent), Double(adjacentOther))).rounded(.toNearestOrAwayFromZero) + 1
                        } else if last < adjacent - 1 && last < adjacentOther - 1 {
                            xx[xx.count - 1] = Float(fmin(Double(adjacent), Double(adjacentOther))).rounded(.toNearestOrAwayFromZero) - 1
                        }
                        break
                    }
                }
            }
            xx.sort()
            for i in stride(from: 1, to: xx.count, by: 2) {
                span(y, roundUp(xx[i - 1]), roundDown(xx[i]))
            }
        }
    }
}

import Foundation

/// 自然 dithering (shared/DITHER.md §2-§5; Python: image.natural): each colour is mapped to what
/// the panel can really show, in linear light, then serpentine Stucki error diffusion matches
/// it against the panel's own colours, using only black, white and the two inks either side of
/// its hue. Every value is a Double computed in the order the spec writes it (no fused
/// multiply-add, no reassociation, nothing rounded), so every app gives the same indices
/// (shared/vectors/natural-vectors.json).
enum Natural {
    /// shared/dither/natural-tables.json (§3), each double parsed from its decimal string.
    struct Tables: Sendable {
        let paletteSRGB: [[Int]]
        /// DEC: input byte -> linear light, with the contrast curve.
        let decode: [Double]
        /// PAL: the panel colours in linear light, 3 per colour.
        let palLin: [Double]
        let luma: [Double]
        let k: [Double]
        let wk: [Double]
        let yk: Double
        let yrange: Double
        let facets: [(nx: Double, ny: Double, nz: Double, d: Double)]
        let e1: [Double]
        let e2: [Double]
        let sectors: [(Int, Int)]
        let sectorXY: [(ax: Double, ay: Double, bx: Double, by: Double)]
        let sat: Double
        let dead: Double
        let knee: Double
        let alpha: Double
        let stucki: [(w: Int, dx: Int, dy: Int)]
        let stuckiDiv: Int

        /// The doubles of `key`, from decimal strings (hex floats for the `_hex` keys), nested
        /// lists flattened row by row.
        static func doubles(_ json: [String: Any], _ key: String) -> [Double] {
            func flat(_ value: Any) -> [Double] {
                if let list = value as? [Any] { return list.flatMap(flat) }
                guard let text = value as? String, let double = Double(text) else {
                    preconditionFailure("natural tables: \(key) holds \(value)")
                }
                return [double]
            }
            return flat(json[key] as Any)
        }

        init(json text: String) {
            // The tables are part of the source, so they cannot fail to parse.
            let json = try! JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
            func one(_ key: String) -> Double { Self.doubles(json, key)[0] }
            func ints(_ key: String) -> [[Int]] { json[key] as! [[Int]] }
            paletteSRGB = ints("palette_srgb")
            decode = Self.doubles(json, "decode")
            palLin = Self.doubles(json, "pal_lin")
            luma = Self.doubles(json, "luma")
            k = Self.doubles(json, "k")
            wk = Self.doubles(json, "wk")
            yk = one("yk")
            yrange = one("yrange")
            facets = stride(from: 0, to: 40, by: 4).map { [f = Self.doubles(json, "facets")] i in
                (f[i], f[i + 1], f[i + 2], f[i + 3])
            }
            e1 = Self.doubles(json, "e1")
            e2 = Self.doubles(json, "e2")
            sectors = ints("sectors").map { ($0[0], $0[1]) }
            sectorXY = stride(from: 0, to: 20, by: 4).map { [s = Self.doubles(json, "sector_xy")] i in
                (s[i], s[i + 1], s[i + 2], s[i + 3])
            }
            sat = one("sat")
            dead = one("dead")
            knee = one("knee")
            alpha = one("alpha")
            stucki = ints("stucki").map { ($0[0], $0[1], $0[2]) }
            stuckiDiv = json["stucki_div"] as! Int
            precondition(decode.count == 256 && palLin.count == 21 && facets.count == 10 && sectors.count == 5
                         && stucki.count == 12, "natural tables: unexpected sizes")
        }
    }

    static let tables = Tables(json: tablesJSON)

    /// Step A (§4) for one colour: the target in linear light and the candidate set (-1: black
    /// and white; k: also the two inks of `sectors[k]`).
    static func target(_ r8: UInt8, _ g8: UInt8, _ b8: UInt8,
                       _ t: Tables = tables) -> (t0: Double, t1: Double, t2: Double, set: Int) {
        let l0 = t.luma[0], l1 = t.luma[1], l2 = t.luma[2]
        let k0 = t.k[0], k1 = t.k[1], k2 = t.k[2]
        let w0 = t.wk[0], w1 = t.wk[1], w2 = t.wk[2]
        var r = t.decode[Int(r8)], g = t.decode[Int(g8)], b = t.decode[Int(b8)]
        let y = l0 * r + l1 * g + l2 * b  // saturation x1.3 around the pixel's luminance
        r = y + t.sat * (r - y); g = y + t.sat * (g - y); b = y + t.sat * (b - y)
        r = k0 + w0 * r; g = k1 + w1 * g; b = k2 + w2 * b  // black-point compensation
        var u = (l0 * r + l1 * g + l2 * b - t.yk) / t.yrange
        u = u < 0 ? 0 : (u > 1 ? 1 : u)
        let g0 = k0 + w0 * u, g1 = k1 + w1 * u, g2 = k2 + w2 * u  // panel grey of the same luminance
        let d0 = r - g0, d1 = g - g1, d2 = b - g2
        var s = Double.infinity
        for (nx, ny, nz, dd) in t.facets {  // where the hull boundary lies along d
            let nd = nx * d0 + ny * d1 + nz * d2
            if nd > 1e-12 {
                let v = (dd - (nx * g0 + ny * g1 + nz * g2)) / nd
                if v < s { s = v }
            }
        }
        let ratio = s == .infinity ? 0 : (s <= 0 ? .infinity : 1 / s)  // 1 = on the hull boundary
        if ratio <= t.dead || ratio == .infinity {  // near-grey: exact panel grey
            return (g0, g1, g2, -1)
        }
        var r1 = (ratio - t.dead) / (1 - t.dead)
        if r1 > t.knee {  // soft knee into the hull
            let x = (r1 - t.knee) / (1 - t.knee)
            r1 = t.knee + (1 - t.knee) * x / (1 + x)
        }
        let f = r1 / ratio
        let x = t.e1[0] * d0 + t.e1[1] * d1 + t.e1[2] * d2
        let y2 = t.e2[0] * d0 + t.e2[1] * d1 + t.e2[2] * d2
        let set = t.sectorXY.firstIndex { ax, ay, bx, by in ax * y2 - ay * x >= 0 && x * by - y2 * bx > 0 } ?? 0
        return (g0 + f * d0, g1 + f * d1, g2 + f * d2, set)
    }

    /// One palette index per pixel of `rgb` (3 bytes a pixel, row-major, `width` x `height`):
    /// step A for each pixel, then step B (§5), the error scaled by `strength`.
    static func indices(_ rgb: [UInt8], width: Int, height: Int, strength: Double,
                        _ t: Tables = tables) -> [UInt8] {
        precondition(rgb.count == width * height * 3, "expected \(width)x\(height) RGB")
        var targets = [Double](repeating: 0, count: width * height * 3)
        var sets = [Int](repeating: -1, count: width * height)
        for p in 0..<(width * height) {
            let a = target(rgb[3 * p], rgb[3 * p + 1], rgb[3 * p + 2], t)
            targets[3 * p] = a.t0
            targets[3 * p + 1] = a.t1
            targets[3 * p + 2] = a.t2
            sets[p] = a.set
        }
        return diffuse(targets, sets, width: width, height: height, strength: strength, t)
    }

    /// Step B (§5): serpentine Stucki error diffusion of the targets in linear light. Raw
    /// memory and while loops: the same arithmetic, but fast in debug builds (the tests) too.
    private static func diffuse(_ targets: [Double], _ sets: [Int], width: Int, height: Int, strength: Double,
                                _ t: Tables) -> [UInt8] {
        let target = copied(targets), set = copied(sets), pal = copied(t.palLin)
        // Candidates in §4's order, 4 per set (set -1 first: black and white only).
        let cand = copied([0, 1, 0, 0] + t.sectors.flatMap { [0, 1, $0.0, $0.1] })
        let count = copied([2] + t.sectors.map { _ in 4 })
        let tapF = copied(t.stucki.map { Double($0.w) / Double(t.stuckiDiv) * strength })  // (w / 42) * s
        let tapDX = copied(t.stucki.map(\.dx)), tapDY = copied(t.stucki.map(\.dy)), taps = t.stucki.count
        // The error of rows y, y+1 and y+2, row y + i at (y + i) % 3: 3 doubles a pixel.
        let err = copied([Double](repeating: 0, count: 3 * width * 3))
        let index = copied([UInt8](repeating: 0, count: width * height))
        defer {
            target.deallocate(); set.deallocate(); pal.deallocate(); cand.deallocate(); count.deallocate()
            tapF.deallocate(); tapDX.deallocate(); tapDY.deallocate(); err.deallocate(); index.deallocate()
        }
        let l0 = t.luma[0], l1 = t.luma[1], l2 = t.luma[2], alpha = t.alpha
        var y = 0
        while y < height {
            let odd = y % 2 == 1, sgn = odd ? -1 : 1
            let row = (y % 3) * width * 3
            var n = 0
            while n < width {
                let x = odd ? width - 1 - n : n  // even rows left to right, odd rows right to left
                let p = y * width + x, e = row + 3 * x
                let v0 = target[3 * p] + err[e], v1 = target[3 * p + 1] + err[e + 1]
                let v2 = target[3 * p + 2] + err[e + 2]
                let s = set[p] + 1
                var best = cand[4 * s], bd = Double.infinity
                var i = 0
                while i < count[s] {
                    let c = cand[4 * s + i]
                    let q0 = pal[3 * c] - v0, q1 = pal[3 * c + 1] - v1, q2 = pal[3 * c + 2] - v2
                    let dy = l0 * q0 + l1 * q1 + l2 * q2
                    let dist = alpha * dy * dy + (q0 - dy) * (q0 - dy) + (q1 - dy) * (q1 - dy) + (q2 - dy) * (q2 - dy)
                    if dist < bd {
                        best = c
                        bd = dist
                    }
                    i += 1
                }
                index[p] = UInt8(best)
                let e0 = v0 - pal[3 * best], e1 = v1 - pal[3 * best + 1], e2 = v2 - pal[3 * best + 2]
                var k = 0
                while k < taps {
                    let f = tapF[k], xx = x + tapDX[k] * sgn, ddy = tapDY[k]
                    if 0 <= xx && xx < width && y + ddy < height {
                        let j = ((y + ddy) % 3) * width * 3 + 3 * xx
                        err[j] += e0 * f
                        err[j + 1] += e1 * f
                        err[j + 2] += e2 * f
                    }
                    k += 1
                }
                n += 1
            }
            (err + row).update(repeating: 0, count: width * 3)  // row y is done: it becomes row y + 3
            y += 1
        }
        return Array(UnsafeBufferPointer(start: index, count: width * height))
    }

    /// `values` in memory of their own, for the raw loops; the caller deallocates it.
    private static func copied<T>(_ values: [T]) -> UnsafeMutablePointer<T> {
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: values.count)
        pointer.initialize(from: values, count: values.count)
        return pointer
    }
}

/// The panel's 7 colours, in the order the firmware expects (index = position).
public enum Palette {
    public static let colours: [(r: UInt8, g: UInt8, b: UInt8)] = [
        (0, 0, 0),        // 0 black
        (255, 255, 255),  // 1 white
        (0, 255, 0),      // 2 green
        (0, 0, 255),      // 3 blue
        (255, 0, 0),      // 4 red
        (255, 255, 0),    // 5 yellow
        (255, 125, 0),    // 6 orange
    ]

    /// Index of the colour with the smallest squared RGB distance to (r, g, b) (each
    /// 0...255); the lowest index wins a tie.
    public static func nearestIndex(r: Int, g: Int, b: Int) -> UInt8 {
        var best = 0
        var bestDistance = Int.max
        for (i, c) in colours.enumerated() {
            let dr = r - Int(c.r), dg = g - Int(c.g), db = b - Int(c.b)
            let distance = dr * dr + dg * dg + db * db
            if distance < bestDistance {
                best = i
                bestDistance = distance
            }
        }
        return UInt8(best)
    }
}

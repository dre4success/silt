import CoreGraphics

/// Squarified treemap layout (Bruls, Huizing & van Wijk, 2000).
///
/// Values are placed largest first. Each row along the short side of the remaining space
/// keeps taking items while that makes its worst aspect ratio better, then is laid down and
/// the space shrinks. Squarish tiles are easier to compare and to hit with a pointer than
/// the slivers a plain slice-and-dice layout produces.
public enum Treemap {
    /// `values` must be sorted largest first. Returns one rect per value, in the same order.
    public static func squarify(_ values: [Double], in rect: CGRect) -> [CGRect] {
        var out = [CGRect](repeating: .zero, count: values.count)
        let total = values.reduce(0) { $0 + max(0, $1) }
        guard total > 0, rect.width > 0, rect.height > 0 else { return out }
        let scale = Double(rect.width * rect.height) / total
        let areas = values.map { max(0, $0) * scale }

        var free = rect
        var i = 0
        while i < areas.count {
            if areas[i] <= 0 { i += 1; continue }
            let side = Double(min(free.width, free.height))
            var j = i
            var sum = 0.0
            var best = Double.infinity
            while j < areas.count, areas[j] > 0 {
                let s = sum + areas[j]
                // Sorted input means the row's largest is areas[i] and its smallest areas[j].
                let w = worst(maxArea: areas[i], minArea: areas[j], sum: s, side: side)
                if w > best { break }
                best = w
                sum = s
                j += 1
            }
            place(areas, from: i, to: j, sum: sum, in: &free, into: &out)
            i = j
        }
        return out
    }

    static func worst(maxArea: Double, minArea: Double, sum: Double, side: Double) -> Double {
        let s2 = sum * sum, w2 = side * side
        return max(w2 * maxArea / s2, s2 / (w2 * minArea))
    }

    private static func place(_ areas: [Double], from i: Int, to j: Int, sum: Double, in free: inout CGRect, into out: inout [CGRect]) {
        if free.width >= free.height {
            // A column down the left edge.
            let w = CGFloat(sum) / free.height
            var y = free.minY
            for k in i..<j {
                let h = CGFloat(areas[k]) / w
                out[k] = CGRect(x: free.minX, y: y, width: w, height: h)
                y += h
            }
            free = CGRect(x: free.minX + w, y: free.minY, width: max(0, free.width - w), height: free.height)
        } else {
            // A row along the top edge.
            let h = CGFloat(sum) / free.width
            var x = free.minX
            for k in i..<j {
                let w = CGFloat(areas[k]) / h
                out[k] = CGRect(x: x, y: free.minY, width: w, height: h)
                x += w
            }
            free = CGRect(x: free.minX, y: free.minY + h, width: free.width, height: max(0, free.height - h))
        }
    }
}

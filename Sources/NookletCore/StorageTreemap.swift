import Foundation

public enum StorageTreemap {
    /// Lay out positive weights in their input order. Give each strip the most square shape available.
    public static func rectangles(weights: [Double], in bounds: CGRect) -> [CGRect] {
        let total = weights.reduce(0, +)
        guard !weights.isEmpty, total.isFinite, total > 0,
              weights.allSatisfy({ $0.isFinite && $0 > 0 }),
              bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else { return [] }

        let areas = weights.map { $0 / total * bounds.width * bounds.height }
        var remaining = bounds
        var rectangles: [CGRect] = []
        var start = 0
        while start < areas.count, remaining.width > 0, remaining.height > 0 {
            let vertical = remaining.width >= remaining.height
            let side = vertical ? remaining.height : remaining.width
            var end = start + 1
            var sum = areas[start]
            var smallest = sum
            var largest = sum
            var score = aspect(sum: sum, smallest: smallest, largest: largest, side: side)
            while end < areas.count {
                let area = areas[end]
                let nextMin = min(smallest, area)
                let nextMax = max(largest, area)
                let nextScore = aspect(sum: sum + area, smallest: nextMin, largest: nextMax, side: side)
                guard nextScore <= score else { break }
                smallest = nextMin
                largest = nextMax
                score = nextScore
                sum += area
                end += 1
            }

            let length = vertical ? remaining.width : remaining.height
            let strip = end == areas.count ? length : min(length, sum / side)
            var offset = 0.0
            for index in start..<end {
                let size = index == end - 1 ? side - offset : min(side - offset, side * (areas[index] / sum))
                let box = vertical
                    ? CGRect(x: remaining.minX, y: remaining.minY + offset, width: strip, height: size)
                    : CGRect(x: remaining.minX + offset, y: remaining.minY, width: size, height: strip)
                rectangles.append(box)
                offset += size
            }
            if vertical {
                remaining.origin.x += strip
                remaining.size.width -= strip
            } else {
                remaining.origin.y += strip
                remaining.size.height -= strip
            }
            start = end
        }
        return rectangles
    }

    private static func aspect(sum: Double, smallest: Double, largest: Double, side: Double) -> Double {
        let sideSquared = side * side
        let sumSquared = sum * sum
        return max(sideSquared * largest / sumSquared, sumSquared / (sideSquared * smallest))
    }
}

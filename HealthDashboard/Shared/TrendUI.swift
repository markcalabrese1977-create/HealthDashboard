import SwiftUI

// MARK: - Trend Sparkline (safe for @ViewBuilder)

struct HDTrendSparkline: View {
    let values: [Double?]

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let pts = normalizedPoints(in: size)

            ZStack {
                // subtle range band
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))

                if pts.count >= 2 {
                    Path { path in
                        path.move(to: pts[0])
                        for p in pts.dropFirst() { path.addLine(to: p) }
                    }
                    .stroke(Color.primary.opacity(0.85), lineWidth: 2)
                } else if pts.count == 1 {
                    Circle()
                        .fill(Color.primary.opacity(0.85))
                        .frame(width: 6, height: 6)
                        .position(pts[0])
                }

                if let last = pts.last {
                    Circle()
                        .fill(Color.primary.opacity(0.9))
                        .frame(width: 6, height: 6)
                        .position(last)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - Helpers (NOT inside ViewBuilder)

    private func normalizedPoints(in size: CGSize) -> [CGPoint] {
        let nums = values.compactMap { $0 }
        guard !nums.isEmpty else { return [] }

        let minV = nums.min() ?? 0
        let maxV = nums.max() ?? 1
        let span = max(maxV - minV, 0.0001)

        let w = max(size.width, 1)
        let h = max(size.height, 1)

        let count = values.count
        let dx: CGFloat = count > 1 ? w / CGFloat(count - 1) : 0

        var pts: [CGPoint] = []
        pts.reserveCapacity(count)

        for (i, vOpt) in values.enumerated() {
            guard let v = vOpt else { continue }
            let t = (v - minV) / span
            let x = CGFloat(i) * dx
            let y = h - CGFloat(t) * h
            pts.append(CGPoint(x: x, y: y))
        }

        return pts
    }
}

// MARK: - Trend math helpers

func hdMedian(_ xs: [Double]) -> Double? {
    let s = xs.sorted()
    guard !s.isEmpty else { return nil }
    if s.count % 2 == 1 { return s[s.count / 2] }
    let a = s[(s.count / 2) - 1]
    let b = s[s.count / 2]
    return (a + b) / 2.0
}

import SwiftUI

struct Sparkline: View {
    let values: [Double?]          // expects 7 items (nil allowed)
    let lineWidth: CGFloat
    let height: CGFloat
    let showDot: Bool
    let showRangeBand: Bool
    let dotSize: CGFloat

    init(
        values: [Double?],
        lineWidth: CGFloat = 2,
        height: CGFloat = 18,
        showDot: Bool = true,
        showRangeBand: Bool = true,
        dotSize: CGFloat = 5
    ) {
        self.values = values
        self.lineWidth = lineWidth
        self.height = height
        self.showDot = showDot
        self.showRangeBand = showRangeBand
        self.dotSize = dotSize
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height

            let present = values.compactMap { $0 }

            // If fewer than 2 points, draw a subtle placeholder dash
            if present.count < 2 {
                RoundedRectangle(cornerRadius: 2)
                    .frame(height: 2)
                    .foregroundStyle(.secondary)
                    .opacity(0.35)
                    .frame(width: w, height: h, alignment: .center)
            } else {
                let minV = present.min() ?? 0
                let maxV = present.max() ?? 1
                let range = max(maxV - minV, 0.0001)

                ZStack {
                    // Range band (min..max) across the full width
                    if showRangeBand {
                        let yMin = yPos(value: minV, minV: minV, range: range, height: h)
                        let yMax = yPos(value: maxV, minV: minV, range: range, height: h)
                        let top = min(yMin, yMax)
                        let bandHeight = max(abs(yMin - yMax), 2)

                        RoundedRectangle(cornerRadius: 3)
                            .frame(width: w, height: bandHeight)
                            .position(x: w / 2, y: top + bandHeight / 2)
                            .foregroundStyle(.primary)
                            .opacity(0.12)
                    }

                    // Line
                    Path { path in
                        var firstPointSet = false
                        for i in values.indices {
                            guard let v = values[i] else { continue }

                            let x = xPos(index: i, count: values.count, width: w)
                            let y = yPos(value: v, minV: minV, range: range, height: h)

                            if !firstPointSet {
                                path.move(to: CGPoint(x: x, y: y))
                                firstPointSet = true
                            } else {
                                path.addLine(to: CGPoint(x: x, y: y))
                            }
                        }
                    }
                    .stroke(style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
                    .foregroundStyle(.primary)
                    .opacity(0.9)

                    // Dot on most recent non-nil value
                    if showDot, let last = lastPoint(width: w, height: h, minV: minV, range: range) {
                        Circle()
                            .frame(width: dotSize, height: dotSize)
                            .position(x: last.x, y: last.y)
                            .foregroundStyle(.primary)
                    }
                }
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }

    private func xPos(index: Int, count: Int, width: CGFloat) -> CGFloat {
        if count <= 1 { return 0 }
        return CGFloat(index) * (width / CGFloat(count - 1))
    }

    private func yPos(value: Double, minV: Double, range: Double, height: CGFloat) -> CGFloat {
        let t = (value - minV) / range
        let y = (1.0 - t) * Double(height)
        return CGFloat(y)
    }

    private func lastPoint(width w: CGFloat, height h: CGFloat, minV: Double, range: Double) -> CGPoint? {
        guard let lastIndex = values.indices.last(where: { values[$0] != nil }),
              let v = values[lastIndex]
        else { return nil }

        let x = xPos(index: lastIndex, count: values.count, width: w)
        let y = yPos(value: v, minV: minV, range: range, height: h)
        return CGPoint(x: x, y: y)
    }
}

// Version 1.0.12
import SwiftUI

struct SparklineView: View {
    let values: [Int]          // 0..100 (%)
    var minY: Int = 0
    var maxY: Int = 100

    var body: some View {
        GeometryReader { geo in
            let w = max(1, geo.size.width)
            let h = max(1, geo.size.height)

            let clamped = values.map { clamp($0, minY, maxY) }
            let pts = points(for: clamped, width: w, height: h, minY: minY, maxY: maxY)

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.06))

                // 0/50/100-linjer
                gridLine(y: yPos(value: 100, height: h), width: w, opacity: 0.22)
                gridLine(y: yPos(value: 50,  height: h), width: w, opacity: 0.16)
                gridLine(y: yPos(value: 0,   height: h), width: w, opacity: 0.22)

                // Labels
                VStack {
                    Text("100%")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.top, 6)
                    Spacer()
                    Text("0%")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 6)
                }
                .padding(.leading, 8)

                if pts.count >= 2 {
                    Path { path in
                        path.move(to: pts[0])
                        for p in pts.dropFirst() { path.addLine(to: p) }
                    }
                    .stroke(
                        Color.primary,
                        style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
                    )
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)

                } else if let only = pts.first {
                    Circle()
                        .fill(Color.primary)
                        .frame(width: 6, height: 6)
                        .position(only)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)

                } else {
                    Path { path in
                        let y = h * 0.5
                        path.move(to: CGPoint(x: 10, y: y))
                        path.addLine(to: CGPoint(x: w - 10, y: y))
                    }
                    .stroke(Color.primary.opacity(0.15),
                            style: StrokeStyle(lineWidth: 2, lineCap: .round))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func clamp(_ v: Int, _ lo: Int, _ hi: Int) -> Int { min(max(v, lo), hi) }

    private func yPos(value: Int, height h: CGFloat) -> CGFloat {
        let span = max(1, maxY - minY)
        let t = CGFloat(value - minY) / CGFloat(span)
        return (1.0 - t) * h
    }

    private func points(for vals: [Int], width w: CGFloat, height h: CGFloat, minY: Int, maxY: Int) -> [CGPoint] {
        guard !vals.isEmpty else { return [] }

        let leftPad: CGFloat = 10
        let rightPad: CGFloat = 10
        let topPad: CGFloat = 8
        let bottomPad: CGFloat = 8

        let innerW = max(1, w - leftPad - rightPad)
        let innerH = max(1, h - topPad - bottomPad)

        let span = max(1, maxY - minY)
        let n = vals.count

        return vals.enumerated().map { (i, v) in
            let x = leftPad + (n == 1 ? innerW * 0.5 : innerW * CGFloat(i) / CGFloat(n - 1))
            let t = CGFloat(v - minY) / CGFloat(span)
            let y = topPad + (1.0 - t) * innerH
            return CGPoint(x: x, y: y)
        }
    }

    private func gridLine(y: CGFloat, width w: CGFloat, opacity: Double) -> some View {
        Path { path in
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: w, y: y))
        }
        .stroke(Color.primary.opacity(opacity),
                style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
    }
}

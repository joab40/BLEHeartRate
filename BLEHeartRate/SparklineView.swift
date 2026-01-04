import SwiftUI

struct SparklineView: View {
    let values: [Int] // 0..200-ish

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let vals = Array(values.suffix(120)) // senaste ~120 punkter

            if vals.count < 2 {
                RoundedRectangle(cornerRadius: 10)
                    .fill(.quaternary)
            } else {
                let minV = max(0, vals.min() ?? 0)
                let maxV = max(minV + 1, vals.max() ?? 1)

                Path { p in
                    for (i, v) in vals.enumerated() {
                        let x = w * CGFloat(i) / CGFloat(vals.count - 1)
                        let norm = CGFloat(v - minV) / CGFloat(maxV - minV)
                        let y = h - (norm * h)

                        if i == 0 { p.move(to: CGPoint(x: x, y: y)) }
                        else { p.addLine(to: CGPoint(x: x, y: y)) }
                    }
                }
                .stroke(lineWidth: 2)
                .foregroundStyle(.primary.opacity(0.9))
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(.quaternary.opacity(0.8))
                )
            }
        }
        .frame(height: 46)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

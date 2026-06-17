import SwiftUI

/// A horizontal pill-shaped slider in the macOS Control Center style: dark
/// rounded-rect background, a lighter fill from the leading edge to the
/// current value, and an SF Symbol embedded in the leading inset. No
/// separate thumb — the fill *is* the value.
///
/// Drag anywhere on the slider to set the value. Hovering shows a subtle
/// elevation; pressing engages a tighter "pressed" look.
struct IconSlider: View {
    /// Stable identifier used so SwiftUI can correctly diff multiple sliders
    /// in the same row (otherwise gesture state can leak between them).
    let icon: String
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    var tint: Color = .white.opacity(0.92)
    var background: Color = Color.white.opacity(0.12)

    @State private var isDragging = false

    private let height: CGFloat = 30
    private let corner: CGFloat = 15

    var body: some View {
        GeometryReader { geo in
            let trackWidth = geo.size.width
            let fillFraction = CGFloat(normalised(value))
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(background)

                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(tint)
                    .frame(width: max(height, trackWidth * fillFraction))
                    .animation(isDragging ? nil : .easeOut(duration: 0.18), value: fillFraction)

                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(iconForeground(fillFraction: fillFraction))
                    .padding(.leading, 11)
                    .allowsHitTesting(false)
            }
            .frame(height: height)
            .contentShape(RoundedRectangle(cornerRadius: corner))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if !isDragging { isDragging = true }
                        update(from: g.location.x, in: trackWidth)
                    }
                    .onEnded { _ in
                        isDragging = false
                    }
            )
        }
        .frame(height: height)
    }

    private func normalised(_ v: Double) -> Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return min(max(0, (v - range.lowerBound) / span), 1)
    }

    private func update(from x: CGFloat, in width: CGFloat) {
        guard width > 0 else { return }
        let f = min(max(0, Double(x / width)), 1)
        let span = range.upperBound - range.lowerBound
        value = range.lowerBound + f * span
    }

    /// When the fill covers the icon, switch the icon to a dark glyph so it
    /// stays legible against the bright fill.
    private func iconForeground(fillFraction: CGFloat) -> Color {
        let coversIcon = (fillFraction * 1.0) > 0.10
        return coversIcon ? Color.black.opacity(0.78) : Color.white.opacity(0.75)
    }
}

import SwiftUI

/// A filled area sparkline chart showing recent activity.
struct SparklineView: View {
    let data: [Float]
    let color: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var accessibilityDescription: String {
        guard !data.isEmpty, !data.allSatisfy({ $0 == 0.0 }) else {
            return "Sparkline chart, no activity"
        }
        let peak = data.max() ?? 0
        let avg = data.reduce(0, +) / Float(data.count)
        return "Sparkline chart, \(data.count) points, peak \(Int(peak * 100))%, average \(Int(avg * 100))%"
    }

    var body: some View {
        GeometryReader { geometry in
            if data.isEmpty || data.allSatisfy({ $0 == 0.0 }) {
                Path { path in
                    path.move(to: CGPoint(x: 0, y: geometry.size.height))
                    path.addLine(to: CGPoint(x: geometry.size.width, y: geometry.size.height))
                }
                .stroke(color.opacity(0.3), lineWidth: 1)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: data)
            } else {
                Path { path in
                    let width = geometry.size.width
                    let height = geometry.size.height
                    let count = data.count
                    guard count > 0 else { return }

                    let step = width / CGFloat(max(count - 1, 1))

                    path.move(to: CGPoint(x: 0, y: height))

                    for (index, value) in data.enumerated() {
                        let x = CGFloat(index) * step
                        let y = height * (1.0 - CGFloat(value))
                        path.addLine(to: CGPoint(x: x, y: y))
                    }

                    path.addLine(to: CGPoint(x: width, y: height))
                    path.closeSubpath()
                }
                .fill(color.opacity(0.3))

                Path { path in
                    let width = geometry.size.width
                    let height = geometry.size.height
                    let count = data.count
                    guard count > 0 else { return }

                    let step = width / CGFloat(max(count - 1, 1))

                    if let firstValue = data.first {
                        let y = height * (1.0 - CGFloat(firstValue))
                        path.move(to: CGPoint(x: 0, y: y))
                    }

                    for (index, value) in data.dropFirst().enumerated() {
                        let x = CGFloat(index + 1) * step
                        let y = height * (1.0 - CGFloat(value))
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                }
                .stroke(color, lineWidth: 1)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: data)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
    }
}

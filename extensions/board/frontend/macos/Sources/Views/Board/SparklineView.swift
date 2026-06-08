import SwiftUI

/// A filled area sparkline chart showing recent activity.
///
/// Takes an array of Float values in [0.0, 1.0] (typically 60 data points
/// for the last minute of activity) and renders a filled area path with
/// smooth line interpolation. Used to show agent output activity on Board cards.
struct SparklineView: View {
    let data: [Float]
    let color: Color
    
    /// Whether to reduce motion (instant transitions vs animated).
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    
    var body: some View {
        GeometryReader { geometry in
            if data.isEmpty || data.allSatisfy({ $0 == 0.0 }) {
                // Empty or all-zero data: flat line at bottom
                Path { path in
                    path.move(to: CGPoint(x: 0, y: geometry.size.height))
                    path.addLine(to: CGPoint(x: geometry.size.width, y: geometry.size.height))
                }
                .stroke(color.opacity(0.3), lineWidth: 1)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: data)
            } else {
                // Draw filled area path
                Path { path in
                    let width = geometry.size.width
                    let height = geometry.size.height
                    let count = data.count
                    guard count > 0 else { return }
                    
                    let step = width / CGFloat(max(count - 1, 1))
                    
                    // Start at bottom-left
                    path.move(to: CGPoint(x: 0, y: height))
                    
                    // Line through data points
                    for (index, value) in data.enumerated() {
                        let x = CGFloat(index) * step
                        let y = height * (1.0 - CGFloat(value))
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                    
                    // Close path at bottom-right
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
                    
                    // Draw just the top line
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
    }
}

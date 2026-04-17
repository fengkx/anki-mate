import SwiftUI

struct StatusPulseDot: View {
    let color: Color
    var isPulsing: Bool = false

    @State private var animated = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .scaleEffect(isPulsing && animated ? 1.22 : 0.9)
            .opacity(isPulsing && animated ? 0.45 : 1.0)
            .animation(
                isPulsing
                    ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
                    : .default,
                value: animated
            )
            .onAppear {
                animated = true
            }
            .onChange(of: isPulsing) { _ in
                animated = isPulsing
            }
    }
}

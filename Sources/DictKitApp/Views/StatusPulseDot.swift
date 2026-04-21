import SwiftUI

struct StatusPulseDot: View {
    let color: Color
    var isPulsing: Bool = false

    @State private var pulsePhase = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .scaleEffect(isPulsing && pulsePhase ? 1.22 : 0.9)
            .opacity(isPulsing && pulsePhase ? 0.45 : 1.0)
            .task(id: isPulsing) {
                if !isPulsing {
                    pulsePhase = false
                    return
                }

                pulsePhase = false
                while !Task.isCancelled {
                    withAnimation(.easeInOut(duration: 0.9)) {
                        pulsePhase.toggle()
                    }
                    try? await Task.sleep(for: .milliseconds(900))
                }
            }
    }
}

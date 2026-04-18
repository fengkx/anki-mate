import SwiftUI

#if os(macOS)
import AppKit

private struct HoverCursorModifier: ViewModifier {
    let cursor: NSCursor

    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                guard hovering != isHovering else { return }
                isHovering = hovering
                if hovering {
                    cursor.push()
                } else {
                    NSCursor.pop()
                }
            }
            .onDisappear {
                guard isHovering else { return }
                isHovering = false
                NSCursor.pop()
            }
    }
}

extension View {
    func hoverCursor(_ cursor: NSCursor = .pointingHand) -> some View {
        modifier(HoverCursorModifier(cursor: cursor))
    }
}
#else
extension View {
    func hoverCursor(_ cursor: Any? = nil) -> some View {
        self
    }
}
#endif

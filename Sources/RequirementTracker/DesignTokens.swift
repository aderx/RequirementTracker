import AppKit
import SwiftUI

enum DesignColor {
    static let textPrimary = Color(hex: 0x1C1B18)
    static let textSecondary = Color.black.opacity(0.55)
    static let textTertiary = Color.black.opacity(0.30)

    static let todo = Color(hex: 0x8A8A90)
    static let doing = Color(hex: 0x007AFF)
    static let devDone = Color(hex: 0x5E5CE6)
    static let tested = Color(hex: 0x0A9BB5)
    static let merged = Color(hex: 0x2A9E48)
    static let paused = Color(hex: 0xD97A09)
    static let stopped = Color(hex: 0xE0463E)
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255,
            opacity: opacity
        )
    }
}

private struct PointingHandCursorModifier: ViewModifier {
    @State private var isCursorPushed = false

    func body(content: Content) -> some View {
        content
            .background(PointingHandCursorArea())
            .onHover { isHovering in
                if isHovering, !isCursorPushed {
                    NSCursor.pointingHand.push()
                    isCursorPushed = true
                } else if !isHovering, isCursorPushed {
                    NSCursor.pop()
                    isCursorPushed = false
                }
            }
            .onDisappear {
                if isCursorPushed {
                    NSCursor.pop()
                    isCursorPushed = false
                }
            }
    }
}

extension View {
    func pointingHandCursor() -> some View {
        modifier(PointingHandCursorModifier())
    }
}

private struct PointingHandCursorArea: NSViewRepresentable {
    func makeNSView(context: Context) -> CursorRectView {
        CursorRectView()
    }

    func updateNSView(_ nsView: CursorRectView, context: Context) {
        nsView.window?.invalidateCursorRects(for: nsView)
    }
}

private final class CursorRectView: NSView {
    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseMoved(with event: NSEvent) {
        NSCursor.pointingHand.set()
    }
}

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
    func body(content: Content) -> some View {
        content
            .overlay(
                PointingHandCursorArea()
                    .allowsHitTesting(false)
            )
            .onHover { isHovering in
                if isHovering {
                    NSCursor.pointingHand.set()
                }
            }
    }
}

extension View {
    @ViewBuilder
    func pointingHandCursor(_ isEnabled: Bool = true) -> some View {
        if isEnabled {
            modifier(PointingHandCursorModifier())
        } else {
            self
        }
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
    private var trackingAreaRef: NSTrackingArea?

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func updateTrackingAreas() {
        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }

        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved, .cursorUpdate],
            owner: self
        )
        addTrackingArea(area)
        trackingAreaRef = area
        super.updateTrackingAreas()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.pointingHand.set()
    }

    override func mouseEntered(with event: NSEvent) {
        NSCursor.pointingHand.set()
    }

    override func mouseMoved(with event: NSEvent) {
        NSCursor.pointingHand.set()
    }
}

import AppKit
import RequirementCore
import SwiftUI

enum DesignColor {
    static let textPrimary = Color.primary
    static let textSecondary = Color.secondary
    static let textTertiary = Color(nsColor: .tertiaryLabelColor)
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let card = adaptive(light: 0xFAFAFA, dark: 0x2C2C2E)
    static let border = Color.primary.opacity(0.12)

    static let todo = adaptive(light: 0x8A8A90, dark: 0xAEAEB2)
    static let doing = adaptive(light: 0x007AFF, dark: 0x409CFF)
    static let devDone = adaptive(light: 0x5E5CE6, dark: 0x9B99FF)
    static let tested = adaptive(light: 0x0A9BB5, dark: 0x5AC8DA)
    static let merged = adaptive(light: 0x2A9E48, dark: 0x5BD477)
    static let mrMergeRequested = adaptive(light: 0xC98A00, dark: 0xEAC35B)
    static let mrMerged = adaptive(light: 0x08783E, dark: 0x60D898)
    static let paused = adaptive(light: 0xD97A09, dark: 0xFFB340)
    static let stopped = adaptive(light: 0xE0463E, dark: 0xFF6961)

    // 保留浅色模式的状态色；深色模式提高亮度，避免文字和标签融入材质背景。
    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(
                srgbRed: Double((value >> 16) & 0xff) / 255,
                green: Double((value >> 8) & 0xff) / 255,
                blue: Double(value & 0xff) / 255,
                alpha: 1
            )
        })
    }
}

extension RequirementMRTrackingStatus {
    var tint: Color {
        switch self {
        case .created:
            DesignColor.merged
        case .mergeRequested:
            DesignColor.mrMergeRequested
        case .merged:
            DesignColor.mrMerged
        }
    }
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

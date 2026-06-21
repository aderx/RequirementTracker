import AppKit
import SwiftUI

struct NativeMenuItemDescriptor: Identifiable {
    let id = UUID()
    let title: String
    let systemImage: String?
    let isEnabled: Bool
    let isDestructive: Bool
    let action: @MainActor () -> Void

    init(
        title: String,
        systemImage: String? = nil,
        isEnabled: Bool = true,
        isDestructive: Bool = false,
        action: @escaping @MainActor () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.isEnabled = isEnabled
        self.isDestructive = isDestructive
        self.action = action
    }
}

enum NativeMenuContent: Identifiable {
    case item(NativeMenuItemDescriptor)
    case separator(UUID = UUID())

    var id: UUID {
        switch self {
        case let .item(item):
            item.id
        case let .separator(id):
            id
        }
    }
}

enum NativeIconMenuKind {
    case more
    case settings
}

struct NativeIconMenuButton: NSViewRepresentable {
    let kind: NativeIconMenuKind
    let contents: [NativeMenuContent]
    var size = CGSize(width: 22, height: 20)
    var tintAlpha: CGFloat = 0.45
    var help: String?

    func makeCoordinator() -> Coordinator {
        Coordinator(contents: contents)
    }

    func makeNSView(context: Context) -> IconMenuButton {
        let button = IconMenuButton()
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.imagePosition = .imageOnly
        button.focusRingType = .none
        button.target = nil
        button.action = nil
        button.setButtonType(.momentaryChange)
        return button
    }

    func updateNSView(_ button: IconMenuButton, context: Context) {
        context.coordinator.contents = contents
        button.buttonSize = size
        button.image = Self.image(for: kind)
        button.contentTintColor = NSColor.labelColor.withAlphaComponent(tintAlpha)
        button.toolTip = help
        button.onPress = { [coordinator = context.coordinator] sender in
            coordinator.showMenu(sender)
        }
        button.needsDisplay = true
        button.invalidateIntrinsicContentSize()
    }

    private static func image(for kind: NativeIconMenuKind) -> NSImage? {
        switch kind {
        case .more:
            moreImage()
        case .settings:
            settingsImage()
        }
    }

    private static func settingsImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 14, height: 14))
        image.lockFocus()

        let stroke = NSBezierPath()
        stroke.lineWidth = 1.65
        stroke.lineCapStyle = .round

        for y in [3.5, 7, 10.5] {
            stroke.move(to: NSPoint(x: 2, y: y))
            stroke.line(to: NSPoint(x: 12, y: y))
        }

        NSColor.black.setStroke()
        stroke.stroke()

        NSColor.black.setFill()
        NSBezierPath(ovalIn: NSRect(x: 4.1, y: 2.05, width: 2.9, height: 2.9)).fill()
        NSBezierPath(ovalIn: NSRect(x: 8.3, y: 5.55, width: 2.9, height: 2.9)).fill()
        NSBezierPath(ovalIn: NSRect(x: 5.4, y: 9.05, width: 2.9, height: 2.9)).fill()

        image.unlockFocus()
        image.isTemplate = true
        image.accessibilityDescription = "设置"
        return image
    }

    private static func moreImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 13, height: 13))
        image.lockFocus()

        NSColor.black.setFill()
        for y in [2.6, 6.5, 10.4] {
            NSBezierPath(ovalIn: NSRect(x: 5.45, y: y, width: 2.1, height: 2.1)).fill()
        }

        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    @MainActor
    final class Coordinator: NSObject {
        var contents: [NativeMenuContent]

        init(contents: [NativeMenuContent]) {
            self.contents = contents
        }

        @objc
        func showMenu(_ sender: NSButton) {
            let menu = NSMenu()
            menu.autoenablesItems = false

            for content in contents {
                switch content {
                case let .item(descriptor):
                    let item = NSMenuItem(title: descriptor.title, action: #selector(performItem(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = descriptor.id
                    item.isEnabled = descriptor.isEnabled

                    if let systemImage = descriptor.systemImage {
                        item.image = menuImage(
                            systemImage: systemImage,
                            title: descriptor.title,
                            isDestructive: descriptor.isDestructive
                        )
                    }

                    if descriptor.isDestructive {
                        item.attributedTitle = NSAttributedString(
                            string: descriptor.title,
                            attributes: [.foregroundColor: NSColor.systemRed]
                        )
                    }

                    menu.addItem(item)
                case .separator:
                    menu.addItem(.separator())
                }
            }

            menu.update()
            let point = menuOrigin(for: sender, menuSize: menu.size)
            menu.popUp(positioning: nil, at: point, in: sender)
        }

        private func menuImage(systemImage: String, title: String, isDestructive: Bool) -> NSImage? {
            guard let image = NSImage(systemSymbolName: systemImage, accessibilityDescription: title) else {
                return nil
            }

            let pointSize: CGFloat = isDestructive ? 13 : 15
            let configuredImage = image.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
            ) ?? image

            if isDestructive {
                return configuredImage.tinted(
                    with: .systemRed,
                    canvasSize: NSSize(width: 15, height: 15),
                    symbolSize: NSSize(width: 11, height: 11)
                )
            }

            configuredImage.size = NSSize(width: 15, height: 15)
            return configuredImage
        }

        private func menuOrigin(for sender: NSButton, menuSize: NSSize) -> NSPoint {
            guard let window = sender.window else {
                return NSPoint(
                    x: sender.bounds.maxX - menuSize.width,
                    y: sender.bounds.minY - 4
                )
            }

            let buttonInWindow = sender.convert(sender.bounds, to: nil)
            let buttonOnScreen = window.convertToScreen(buttonInWindow)
            let screen = NSScreen.screens.first { screen in
                screen.visibleFrame.intersects(buttonOnScreen)
            } ?? sender.window?.screen ?? NSScreen.main
            let visibleFrame = screen?.visibleFrame ?? NSScreen.screens.first?.visibleFrame ?? .zero

            let belowTopY = buttonOnScreen.minY - 4
            let aboveTopY = buttonOnScreen.maxY + menuSize.height + 4
            let y = belowTopY - menuSize.height >= visibleFrame.minY
                ? belowTopY
                : min(aboveTopY, visibleFrame.maxY)

            let candidates = [
                buttonOnScreen.maxX - menuSize.width,
                buttonOnScreen.midX - menuSize.width / 2,
                buttonOnScreen.minX
            ]
            let x = candidates.first { candidate in
                candidate >= visibleFrame.minX && candidate + menuSize.width <= visibleFrame.maxX
            } ?? min(max(buttonOnScreen.maxX - menuSize.width, visibleFrame.minX), visibleFrame.maxX - menuSize.width)

            let screenOrigin = NSPoint(x: x, y: y)
            let originInWindow = window.convertFromScreen(NSRect(origin: screenOrigin, size: .zero)).origin
            return sender.convert(originInWindow, from: nil)
        }

        @objc
        private func performItem(_ sender: NSMenuItem) {
            guard
                let id = sender.representedObject as? UUID,
                let descriptor = contents.compactMap(\.itemDescriptor).first(where: { $0.id == id })
            else {
                return
            }

            descriptor.action()
        }
    }
}

private extension NSImage {
    func tinted(
        with color: NSColor,
        canvasSize: NSSize? = nil,
        symbolSize: NSSize? = nil
    ) -> NSImage {
        let canvasSize = canvasSize ?? size
        let symbolSize = symbolSize ?? canvasSize
        let image = NSImage(size: canvasSize)
        image.lockFocus()
        let rect = NSRect(
            x: (canvasSize.width - symbolSize.width) / 2,
            y: (canvasSize.height - symbolSize.height) / 2,
            width: symbolSize.width,
            height: symbolSize.height
        )
        draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        color.setFill()
        rect.fill(using: .sourceAtop)
        image.unlockFocus()
        image.isTemplate = false
        return image
    }
}

private extension NativeMenuContent {
    var itemDescriptor: NativeMenuItemDescriptor? {
        if case let .item(descriptor) = self {
            return descriptor
        }

        return nil
    }
}

@MainActor
final class IconMenuButton: NSButton {
    var buttonSize = CGSize(width: 22, height: 20)
    var onPress: ((IconMenuButton) -> Void)?
    private var isHovering = false
    private var trackingAreaRef: NSTrackingArea?

    override var intrinsicContentSize: NSSize {
        NSSize(width: buttonSize.width, height: buttonSize.height)
    }

    override func updateTrackingAreas() {
        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }

        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited],
            owner: self
        )
        addTrackingArea(area)
        trackingAreaRef = area
        super.updateTrackingAreas()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        NSCursor.pointingHand.set()
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        NSCursor.pointingHand.set()
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        isHighlighted = true
        needsDisplay = true
        onPress?(self)
        isHighlighted = false
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        if isHovering || isHighlighted {
            NSColor.black.withAlphaComponent(isHighlighted ? 0.10 : 0.06).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        }

        super.draw(dirtyRect)
    }
}

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
            NSImage(
                systemSymbolName: "gearshape",
                accessibilityDescription: "设置"
            )?.withSymbolConfiguration(.init(pointSize: 13.5, weight: .semibold))
        }
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
                        item.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: descriptor.title)
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

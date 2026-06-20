import AppKit
import SwiftUI

@main
struct RequirementTrackerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = RequirementStore()
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var resignActiveObserver: NSObjectProtocol?
    private let panelWidth = RequirementPanelMetrics.width

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.applicationIconImage = Self.makeAppIcon()
        NSApplication.shared.setActivationPolicy(.accessory)

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item

        if let button = item.button {
            button.image = Self.makeStatusIcon()
            button.imageScaling = .scaleProportionallyDown
            button.imagePosition = .imageOnly
            button.toolTip = "需求记录"
            button.target = self
            button.action = #selector(togglePopover(_:))
        }

        let content = RequirementPanelView { [weak self] isCalendarVisible in
            Task { @MainActor in
                self?.setPanelHeight(isCalendarVisible: isCalendarVisible)
            }
        }
        .environmentObject(store)

        let hostingController = NSHostingController(rootView: content)
        hostingController.view.frame = NSRect(
            origin: .zero,
            size: NSSize(
                width: RequirementPanelMetrics.width,
                height: RequirementPanelMetrics.height(isCalendarVisible: false)
            )
        )

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(
            width: RequirementPanelMetrics.width,
            height: RequirementPanelMetrics.height(isCalendarVisible: false)
        )
        popover.contentViewController = hostingController
        self.popover = popover

        resignActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: NSApplication.shared,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.closePopover()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        removePopoverMonitors()

        if let resignActiveObserver {
            NotificationCenter.default.removeObserver(resignActiveObserver)
        }
    }

    @objc
    private func togglePopover(_ sender: NSStatusBarButton) {
        guard let popover else {
            return
        }

        if popover.isShown {
            closePopover()
        } else {
            NSApplication.shared.activate(ignoringOtherApps: true)
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            focusPopoverWindow()
            installPopoverMonitors()
        }
    }

    private func closePopover() {
        popover?.performClose(nil)
        setPanelHeight(isCalendarVisible: false)
        removePopoverMonitors()
    }

    private func setPanelHeight(isCalendarVisible: Bool) {
        let size = NSSize(
            width: panelWidth,
            height: RequirementPanelMetrics.height(isCalendarVisible: isCalendarVisible)
        )

        popover?.contentSize = size
        popover?.contentViewController?.view.frame.size = size
    }

    private func focusPopoverWindow() {
        guard let popover else {
            return
        }

        DispatchQueue.main.async {
            NSApplication.shared.activate(ignoringOtherApps: true)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func installPopoverMonitors() {
        removePopoverMonitors()

        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            Task { @MainActor in
                self?.closePopoverIfNeeded(for: event)
            }
            return event
        }

        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                self?.closePopover()
            }
        }
    }

    private func removePopoverMonitors() {
        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
            self.localMouseMonitor = nil
        }

        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
            self.globalMouseMonitor = nil
        }
    }

    private func closePopoverIfNeeded(for event: NSEvent) {
        guard popover?.isShown == true else {
            removePopoverMonitors()
            return
        }

        if event.window?.level == .popUpMenu {
            return
        }

        if let popoverWindow = popover?.contentViewController?.view.window,
           event.window == popoverWindow {
            return
        }

        closePopover()
    }

    private static func makeStatusIcon() -> NSImage {
        let size = NSSize(width: 22, height: 22)
        let image = NSImage(size: size)
        image.lockFocus()
        drawStatusIcon(in: NSRect(origin: .zero, size: size))
        image.unlockFocus()
        image.isTemplate = false
        image.accessibilityDescription = "需求记录"
        return image
    }

    private static func makeAppIcon() -> NSImage {
        let size = NSSize(width: 512, height: 512)
        let image = NSImage(size: size)
        image.lockFocus()
        drawAppIcon(in: NSRect(origin: .zero, size: size))
        image.unlockFocus()
        image.accessibilityDescription = "需求记录"
        return image
    }

    private static func drawStatusIcon(in rect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else {
            return
        }

        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.minY + rect.height)
        context.scaleBy(x: rect.width / 22, y: -rect.height / 22)

        drawRoundedRect(
            context,
            rect: CGRect(x: 2.1, y: 5.2, width: 17.8, height: 11.4),
            radius: 2.4,
            fillColor: NSColor.white.cgColor,
            strokeColor: NSColor.white.cgColor,
            lineWidth: 0.1
        )

        strokePolyline(
            context,
            points: [
                CGPoint(x: 7.1, y: 11.3),
                CGPoint(x: 9.4, y: 13.4),
                CGPoint(x: 15.2, y: 7.7)
            ],
            color: NSColor(calibratedWhite: 0.11, alpha: 1).cgColor,
            lineWidth: 1.45
        )

        context.restoreGState()
    }

    private static func drawAppIcon(in rect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            return
        }

        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.minY + rect.height)
        context.scaleBy(x: rect.width / 512, y: -rect.height / 512)

        let iconPath = CGPath(
            roundedRect: CGRect(x: 0, y: 0, width: 512, height: 512),
            cornerWidth: 110,
            cornerHeight: 110,
            transform: nil
        )
        let appGradient = CGGradient(
            colorsSpace: colorSpace,
            colors: [
                NSColor(calibratedRed: 0, green: 122 / 255, blue: 1, alpha: 1).cgColor,
                NSColor(calibratedRed: 0, green: 85 / 255, blue: 204 / 255, alpha: 1).cgColor,
                NSColor(calibratedRed: 0, green: 61 / 255, blue: 153 / 255, alpha: 1).cgColor
            ] as CFArray,
            locations: [0, 0.5, 1]
        )
        context.saveGState()
        context.addPath(iconPath)
        context.clip()
        if let appGradient {
            context.drawLinearGradient(
                appGradient,
                start: CGPoint(x: 0, y: 0),
                end: CGPoint(x: 512, y: 512),
                options: []
            )
        }
        context.restoreGState()

        let shineGradient = CGGradient(
            colorsSpace: colorSpace,
            colors: [
                NSColor.white.withAlphaComponent(0.4).cgColor,
                NSColor.white.withAlphaComponent(0).cgColor,
                NSColor.white.withAlphaComponent(0).cgColor
            ] as CFArray,
            locations: [0, 0.5, 1]
        )
        context.saveGState()
        context.addPath(iconPath)
        context.clip()
        if let shineGradient {
            context.drawLinearGradient(
                shineGradient,
                start: CGPoint(x: 0, y: 0),
                end: CGPoint(x: 512, y: 512),
                options: []
            )
        }
        context.restoreGState()

        context.saveGState()
        context.translateBy(x: 256, y: 256)

        context.saveGState()
        context.rotate(by: -8 * .pi / 180)
        drawRoundedRect(
            context,
            rect: CGRect(x: -60, y: 20, width: 120, height: 70),
            radius: 12,
            fillColor: NSColor.white.withAlphaComponent(0.15).cgColor,
            strokeColor: nil,
            lineWidth: 0
        )
        context.restoreGState()

        context.saveGState()
        context.rotate(by: -4 * .pi / 180)
        drawRoundedRect(
            context,
            rect: CGRect(x: -60, y: 0, width: 120, height: 70),
            radius: 12,
            fillColor: NSColor.white.withAlphaComponent(0.25).cgColor,
            strokeColor: nil,
            lineWidth: 0
        )
        context.restoreGState()

        context.scaleBy(x: 1.8, y: 1.8)
        context.setFillColor(NSColor.white.withAlphaComponent(0.15).cgColor)
        context.fillEllipse(in: CGRect(x: -85, y: -85, width: 170, height: 170))
        strokePolyline(
            context,
            points: [
                CGPoint(x: -40, y: 0),
                CGPoint(x: -10, y: 30),
                CGPoint(x: 50, y: -30)
            ],
            color: NSColor.white.cgColor,
            lineWidth: 18
        )

        context.restoreGState()
        context.restoreGState()
    }

    private static func drawRoundedRect(
        _ context: CGContext,
        rect: CGRect,
        radius: CGFloat,
        fillColor: CGColor,
        strokeColor: CGColor?,
        lineWidth: CGFloat
    ) {
        let path = CGPath(
            roundedRect: rect,
            cornerWidth: radius,
            cornerHeight: radius,
            transform: nil
        )
        context.addPath(path)
        context.setFillColor(fillColor)
        context.fillPath()

        if let strokeColor, lineWidth > 0 {
            context.addPath(path)
            context.setStrokeColor(strokeColor)
            context.setLineWidth(lineWidth)
            context.strokePath()
        }
    }

    private static func strokePolyline(
        _ context: CGContext,
        points: [CGPoint],
        color: CGColor,
        lineWidth: CGFloat
    ) {
        guard let first = points.first else {
            return
        }

        context.beginPath()
        context.move(to: first)
        points.dropFirst().forEach { context.addLine(to: $0) }
        context.setStrokeColor(color)
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.strokePath()
    }
}

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
    private let settingsStore = RequirementSettingsStore()
    private let scriptLauncher = GhosttyScriptLauncher()
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var resignActiveObserver: NSObjectProtocol?
    private var overviewWindowController: NSWindowController?
    private var aboutWindowController: NSWindowController?
    private var settingsWindowController: NSWindowController?
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
            button.toolTip = Self.statusItemTooltip
            button.target = self
            button.action = #selector(togglePopover(_:))
        }

        let content = RequirementPanelView(
            onOpenOverview: { [weak self] in
                self?.openOverview()
            },
            onShowAbout: { [weak self] in
                self?.openAbout()
            },
            onOpenSettings: { [weak self] in
                self?.openSettings()
            },
            onCalendarVisibilityChange: { [weak self] isCalendarVisible in
                Task { @MainActor in
                    self?.setPanelHeight(isCalendarVisible: isCalendarVisible)
                }
            }
        )
        .environmentObject(store)
        .environmentObject(settingsStore)
        .environmentObject(scriptLauncher)

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

    private func openOverview() {
        closePopover()

        if let window = overviewWindowController?.window {
            NSApplication.shared.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let content = RequirementOverviewView()
            .environmentObject(store)
        let hostingController = NSHostingController(rootView: content)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "需求总览"
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 780, height: 560)
        window.contentViewController = hostingController
        window.center()

        let controller = NSWindowController(window: window)
        overviewWindowController = controller
        NSApplication.shared.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
    }

    private func openSettings() {
        closePopover()

        if let window = settingsWindowController?.window {
            NSApplication.shared.activate(ignoringOtherApps: true)
            centerOnMainScreen(window)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let hostingController = NSHostingController(
            rootView: RequirementSettingsView()
                .environmentObject(settingsStore)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "设置"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 680, height: 460)
        window.contentViewController = hostingController
        centerOnMainScreen(window)

        let controller = NSWindowController(window: window)
        settingsWindowController = controller
        NSApplication.shared.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
    }

    private func openAbout() {
        closePopover()

        if let window = aboutWindowController?.window {
            NSApplication.shared.activate(ignoringOtherApps: true)
            centerOnMainScreen(window)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let content = RequirementAboutView(
            appIcon: Self.makeAppIcon(),
            appName: Self.appDisplayName,
            version: Self.appVersion,
            githubURL: Self.githubURL
        )
        let hostingController = NSHostingController(rootView: content)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 272),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "关于"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentViewController = hostingController
        centerOnMainScreen(window)

        let controller = NSWindowController(window: window)
        aboutWindowController = controller
        NSApplication.shared.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
    }

    private func centerOnMainScreen(_ window: NSWindow) {
        let screenFrame = NSScreen.main?.visibleFrame ?? NSScreen.screens.first?.visibleFrame ?? .zero
        guard screenFrame != .zero else {
            window.center()
            return
        }

        window.setFrameOrigin(
            NSPoint(
                x: screenFrame.midX - window.frame.width / 2,
                y: screenFrame.midY - window.frame.height / 2
            )
        )
    }

    private static func makeStatusIcon() -> NSImage {
        let size = NSSize(width: 22, height: 22)
        let image = NSImage(size: size)
        image.lockFocus()
        drawStatusIcon(in: NSRect(origin: .zero, size: size))
        #if DEVELOPMENT
        drawDevelopmentStatusBadge(in: NSRect(origin: .zero, size: size))
        #endif
        image.unlockFocus()
        image.isTemplate = false
        image.accessibilityDescription = statusItemTooltip
        return image
    }

    private static var statusItemTooltip: String {
        #if DEVELOPMENT
        return "需求记录 Dev"
        #else
        return "需求记录"
        #endif
    }

    private static var appDisplayName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "需求记录"
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "1.0"
    }

    private static var githubURL: String? {
        "https://github.com/aderx/RequirementTracker"
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

    private static func drawDevelopmentStatusBadge(in rect: NSRect) {
        let badgeRect = NSRect(
            x: rect.maxX - 8.6,
            y: rect.maxY - 8.9,
            width: 7.6,
            height: 7.6
        )
        let badgePath = NSBezierPath(roundedRect: badgeRect, xRadius: 2.2, yRadius: 2.2)

        NSColor(calibratedRed: 1, green: 149 / 255, blue: 0, alpha: 1).setFill()
        badgePath.fill()

        NSColor.white.withAlphaComponent(0.92).setStroke()
        badgePath.lineWidth = 0.7
        badgePath.stroke()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 5.4, weight: .bold),
            .foregroundColor: NSColor.white
        ]
        let marker = NSString(string: "D")
        let markerSize = marker.size(withAttributes: attributes)
        marker.draw(
            at: NSPoint(
                x: badgeRect.midX - markerSize.width / 2,
                y: badgeRect.midY - markerSize.height / 2 - 0.3
            ),
            withAttributes: attributes
        )
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

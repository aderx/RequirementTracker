import AppKit
import Foundation
import OSLog

enum CalendarDeepLink {
    static func selectedDate(from url: URL) -> Date? {
        guard ["requirementtracker", "requirementtracker-dev"].contains(url.scheme),
              url.host == "calendar",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let rawDate = components.queryItems?.first(where: { $0.name == "date" })?.value,
              let timestamp = TimeInterval(rawDate),
              timestamp.isFinite
        else {
            return nil
        }

        return Date(timeIntervalSince1970: timestamp)
    }
}

enum SystemCalendarLauncher {
    private static let logger = Logger(
        subsystem: "com.xfu-work.RequirementTracker",
        category: "SystemCalendarLauncher"
    )

    @MainActor
    static func openDay(_ date: Date) {
        guard let calendarApplicationURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.apple.iCal"
        ) else {
            logger.error("Calendar.app could not be located")
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        // Send the date as Calendar's launch event so the primary navigation is
        // handled even when Calendar was not running before the widget click.
        configuration.appleEvent = showDateEvent(date)

        NSWorkspace.shared.openApplication(
            at: calendarApplicationURL,
            configuration: configuration
        ) { _, error in
            if let error {
                logger.error("Calendar.app failed to open: \(error.localizedDescription, privacy: .public)")
                return
            }

            do {
                _ = try switchToDayViewEvent().sendEvent(
                    options: [.waitForReply, .canInteract],
                    timeout: 60
                )
            } catch {
                logger.error("Calendar.app rejected date navigation: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private static func switchToDayViewEvent() -> NSAppleEventDescriptor {
        let event = calendarEvent(id: "aeca")
        event.setParam(
            NSAppleEventDescriptor(enumCode: fourCharacterCode("E5da")),
            forKeyword: AEKeyword(fourCharacterCode("wre5"))
        )
        return event
    }

    private static func showDateEvent(_ date: Date) -> NSAppleEventDescriptor {
        let event = calendarEvent(id: "aec9")
        event.setParam(
            NSAppleEventDescriptor(date: date),
            forKeyword: AEKeyword(fourCharacterCode("wtdt"))
        )
        return event
    }

    private static func calendarEvent(id: String) -> NSAppleEventDescriptor {
        NSAppleEventDescriptor(
            eventClass: AEEventClass(fourCharacterCode("wrbt")),
            eventID: AEEventID(fourCharacterCode(id)),
            targetDescriptor: NSAppleEventDescriptor(bundleIdentifier: "com.apple.iCal"),
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
    }

    private static func fourCharacterCode(_ value: String) -> UInt32 {
        value.utf8.reduce(0) { partialResult, byte in
            (partialResult << 8) + UInt32(byte)
        }
    }
}

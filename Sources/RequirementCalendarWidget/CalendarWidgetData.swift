import Foundation
#if canImport(EventKit)
import EventKit
#endif
#if canImport(RequirementCalendarCore)
import RequirementCalendarCore
#endif

enum CalendarWidgetKind {
    static let month = "com.xfu-work.RequirementTracker.calendar.month"
    static let year = "com.xfu-work.RequirementTracker.calendar.year"
}

enum CalendarWidgetScope: Sendable {
    case month
    case year
}

struct CalendarWidgetState: Sendable {
    let displayMonth: Date
    let selectedDate: Date
    let displayYear: Date
}

enum CalendarWidgetStateStore {
    private enum Key {
        static let displayMonth = "calendarWidget.displayMonth"
        static let selectedDate = "calendarWidget.selectedDate"
        static let displayYear = "calendarWidget.displayYear"
    }

    static func read(now: Date = Date()) -> CalendarWidgetState {
        let calendar = CalendarWidgetEnvironment.calendar
        let defaults = UserDefaults.standard
        let selectedDate = storedDate(forKey: Key.selectedDate, defaults: defaults)
            .map(calendar.startOfDay(for:))
            ?? calendar.startOfDay(for: now)
        let displayMonth = storedDate(forKey: Key.displayMonth, defaults: defaults)
            .map { CalendarNavigation.startOfMonth(containing: $0, calendar: calendar) }
            ?? CalendarNavigation.startOfMonth(containing: selectedDate, calendar: calendar)
        let displayYear = storedDate(forKey: Key.displayYear, defaults: defaults)
            .map { CalendarNavigation.startOfYear(containing: $0, calendar: calendar) }
            ?? CalendarNavigation.startOfYear(containing: now, calendar: calendar)

        return CalendarWidgetState(
            displayMonth: displayMonth,
            selectedDate: selectedDate,
            displayYear: displayYear
        )
    }

    static func selectDate(_ date: Date) {
        let calendar = CalendarWidgetEnvironment.calendar
        let selectedDate = calendar.startOfDay(for: date)
        let defaults = UserDefaults.standard
        defaults.set(selectedDate.timeIntervalSince1970, forKey: Key.selectedDate)
        defaults.set(
            CalendarNavigation.startOfMonth(containing: selectedDate, calendar: calendar)
                .timeIntervalSince1970,
            forKey: Key.displayMonth
        )
    }

    static func moveMonth(by offset: Int, now: Date = Date()) {
        let calendar = CalendarWidgetEnvironment.calendar
        let current = read(now: now)
        let sourceDate = calendar.isDate(
            current.selectedDate,
            equalTo: current.displayMonth,
            toGranularity: .month
        ) ? current.selectedDate : current.displayMonth
        let targetDate = CalendarNavigation.movingMonth(
            from: sourceDate,
            by: offset,
            calendar: calendar
        )
        selectDate(targetDate)
    }

    static func moveYear(by offset: Int, now: Date = Date()) {
        let calendar = CalendarWidgetEnvironment.calendar
        let current = read(now: now)
        let targetDate = CalendarNavigation.movingYear(
            from: current.displayYear,
            by: offset,
            calendar: calendar
        )
        UserDefaults.standard.set(
            CalendarNavigation.startOfYear(containing: targetDate, calendar: calendar)
                .timeIntervalSince1970,
            forKey: Key.displayYear
        )
    }

    static func resetMonthToToday(now: Date = Date()) {
        selectDate(now)
    }

    static func resetYearToToday(now: Date = Date()) {
        let calendar = CalendarWidgetEnvironment.calendar
        UserDefaults.standard.set(
            CalendarNavigation.startOfYear(containing: now, calendar: calendar)
                .timeIntervalSince1970,
            forKey: Key.displayYear
        )
    }

    private static func storedDate(forKey key: String, defaults: UserDefaults) -> Date? {
        guard defaults.object(forKey: key) != nil else {
            return nil
        }
        return Date(timeIntervalSince1970: defaults.double(forKey: key))
    }
}

enum CalendarEventAccessState: Sendable {
    case fullAccess
    case notDetermined
    case denied
    case unavailable
}

struct CalendarWidgetEvent: Identifiable, Sendable {
    let id: String
    let title: String
    let startDate: Date
    let isAllDay: Bool
    let isHoliday: Bool
}

struct CalendarEventSnapshot: Sendable {
    let accessState: CalendarEventAccessState
    let eventDayIDs: Set<String>
    let holidayTitleByDayID: [String: String]
    let selectedDayEvents: [CalendarWidgetEvent]

    static let unavailable = CalendarEventSnapshot(
        accessState: .unavailable,
        eventDayIDs: [],
        holidayTitleByDayID: [:],
        selectedDayEvents: []
    )

    static func preview(now: Date) -> CalendarEventSnapshot {
        let calendar = CalendarWidgetEnvironment.calendar
        let start = calendar.date(bySettingHour: 10, minute: 0, second: 0, of: now) ?? now
        return CalendarEventSnapshot(
            accessState: .fullAccess,
            eventDayIDs: [CalendarWidgetEnvironment.dayIdentifier(for: now)],
            holidayTitleByDayID: [:],
            selectedDayEvents: [
                CalendarWidgetEvent(
                    id: "preview",
                    title: "项目例会",
                    startDate: start,
                    isAllDay: false,
                    isHoliday: false
                )
            ]
        )
    }

    func hasEvent(on date: Date) -> Bool {
        eventDayIDs.contains(CalendarWidgetEnvironment.dayIdentifier(for: date))
    }

    func holidayTitle(on date: Date) -> String? {
        holidayTitleByDayID[CalendarWidgetEnvironment.dayIdentifier(for: date)]
    }
}

enum CalendarWidgetEventLoader {
    static func load(
        for state: CalendarWidgetState,
        scope: CalendarWidgetScope
    ) -> CalendarEventSnapshot {
        #if canImport(EventKit)
        let authorizationStatus = EKEventStore.authorizationStatus(for: .event)
        guard authorizationStatus == .fullAccess else {
            return CalendarEventSnapshot(
                accessState: authorizationStatus == .notDetermined ? .notDetermined : .denied,
                eventDayIDs: [],
                holidayTitleByDayID: [:],
                selectedDayEvents: []
            )
        }

        let calendar = CalendarWidgetEnvironment.calendar
        let eventStore = EKEventStore()
        var eventsByID: [String: EKEvent] = [:]

        for interval in eventIntervals(for: state, scope: scope, calendar: calendar) {
            let predicate = eventStore.predicateForEvents(
                withStart: interval.start,
                end: interval.end,
                calendars: nil
            )
            for event in eventStore.events(matching: predicate) {
                eventsByID[eventIdentity(event)] = event
            }
        }

        let events = Array(eventsByID.values)
        var eventDayIDs = Set<String>()
        var holidayTitleByDayID: [String: String] = [:]

        for event in events {
            let holiday = isHoliday(event)
            for day in coveredDays(for: event, calendar: calendar) {
                let dayID = CalendarWidgetEnvironment.dayIdentifier(for: day)
                eventDayIDs.insert(dayID)
                if holiday, holidayTitleByDayID[dayID] == nil {
                    holidayTitleByDayID[dayID] = normalizedTitle(event.title)
                }
            }
        }

        let selectedInterval = calendar.dateInterval(of: .day, for: state.selectedDate)
        let selectedEvents = events
            .filter { event in
                guard let selectedInterval else {
                    return false
                }
                return event.endDate > selectedInterval.start && event.startDate < selectedInterval.end
            }
            .sorted(by: eventSort)
            .map { event in
                CalendarWidgetEvent(
                    id: eventIdentity(event),
                    title: normalizedTitle(event.title),
                    startDate: event.startDate,
                    isAllDay: event.isAllDay,
                    isHoliday: isHoliday(event)
                )
            }

        return CalendarEventSnapshot(
            accessState: .fullAccess,
            eventDayIDs: eventDayIDs,
            holidayTitleByDayID: holidayTitleByDayID,
            selectedDayEvents: selectedEvents
        )
        #else
        return .unavailable
        #endif
    }

    #if canImport(EventKit)
    private static func eventIntervals(
        for state: CalendarWidgetState,
        scope: CalendarWidgetScope,
        calendar: Calendar
    ) -> [DateInterval] {
        switch scope {
        case .month:
            guard let month = calendar.dateInterval(of: .month, for: state.displayMonth) else {
                return []
            }
            if month.contains(state.selectedDate) {
                return [month]
            }
            return [month, calendar.dateInterval(of: .day, for: state.selectedDate)].compactMap { $0 }
        case .year:
            return [calendar.dateInterval(of: .year, for: state.displayYear)].compactMap { $0 }
        }
    }

    private static func eventIdentity(_ event: EKEvent) -> String {
        let identifier = event.eventIdentifier ?? event.calendarItemIdentifier
        return "\(identifier)-\(event.startDate.timeIntervalSince1970)"
    }

    private static func coveredDays(for event: EKEvent, calendar: Calendar) -> [Date] {
        let firstDay = calendar.startOfDay(for: event.startDate)
        let effectiveEnd = max(event.startDate, event.endDate.addingTimeInterval(-0.001))
        let lastDay = calendar.startOfDay(for: effectiveEnd)
        var result: [Date] = []
        var day = firstDay

        while day <= lastDay, result.count < 370 {
            result.append(day)
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: day) else {
                break
            }
            day = nextDay
        }
        return result
    }

    private static func isHoliday(_ event: EKEvent) -> Bool {
        guard event.isAllDay else {
            return false
        }

        let calendarTitle = event.calendar.title.lowercased()
        return ["节假", "假日", "holiday"].contains { calendarTitle.contains($0) }
    }

    private static func normalizedTitle(_ title: String?) -> String {
        let result = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return result.isEmpty ? "未命名日程" : result
    }

    private static func eventSort(_ lhs: EKEvent, _ rhs: EKEvent) -> Bool {
        let lhsHoliday = isHoliday(lhs)
        let rhsHoliday = isHoliday(rhs)
        if lhsHoliday != rhsHoliday {
            return lhsHoliday
        }
        if lhs.isAllDay != rhs.isAllDay {
            return lhs.isAllDay
        }
        return lhs.startDate < rhs.startDate
    }
    #endif
}

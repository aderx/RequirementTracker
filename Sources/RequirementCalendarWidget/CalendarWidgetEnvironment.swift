import Foundation
#if canImport(RequirementCalendarCore)
import RequirementCalendarCore
#endif

enum CalendarWidgetEnvironment {
    static var calendar: Calendar {
        let current = Calendar.autoupdatingCurrent
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = current.locale
        calendar.timeZone = .autoupdatingCurrent
        calendar.firstWeekday = current.firstWeekday
        calendar.minimumDaysInFirstWeek = current.minimumDaysInFirstWeek
        return calendar
    }

    static var locale: Locale {
        .autoupdatingCurrent
    }

    static var builder: CalendarGridBuilder {
        CalendarGridBuilder(calendar: calendar, locale: locale)
    }

    static func weekdayName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("EEEE")
        return formatter.string(from: date)
    }

    static func selectedDateTitle(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("M月d日 EEEE")
        return formatter.string(from: date)
    }

    static func eventTime(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("HH:mm")
        return formatter.string(from: date)
    }

    static func dayIdentifier(for date: Date) -> String {
        let components = calendar.dateComponents([.era, .year, .month, .day], from: date)
        return [components.era, components.year, components.month, components.day]
            .map { String($0 ?? 0) }
            .joined(separator: "-")
    }

    static func calendarDetailURL(for date: Date) -> URL? {
        var components = URLComponents()
        components.scheme = Bundle.main.bundleIdentifier?.contains(".dev.") == true
            ? "requirementtracker-dev"
            : "requirementtracker"
        components.host = "calendar"
        components.queryItems = [
            URLQueryItem(name: "date", value: String(date.timeIntervalSince1970))
        ]
        return components.url
    }
}

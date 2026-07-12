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
}

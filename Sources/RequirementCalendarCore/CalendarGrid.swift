import Foundation

public struct CalendarDay: Equatable, Identifiable {
    public let date: Date
    public let number: Int
    public let isToday: Bool
    public let isWeekend: Bool

    public var id: Date { date }
}

public struct CalendarMonth: Equatable {
    public let startDate: Date
    public let year: Int
    public let month: Int
    public let title: String
    public let weekdaySymbols: [String]
    public let weeks: [[CalendarDay?]]

    public var visibleWeeks: [[CalendarDay?]] {
        var result = weeks
        while result.count > 1, result.last?.allSatisfy({ $0 == nil }) == true {
            result.removeLast()
        }
        return result
    }
}

public struct CalendarYear: Equatable {
    public let startDate: Date
    public let year: Int
    public let title: String
    public let months: [CalendarMonth]
}

public enum CalendarDisplayText {
    public static func year(_ year: Int) -> String {
        String(year) + "年"
    }
}

public enum CalendarNavigation {
    public static func startOfMonth(
        containing date: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> Date {
        let components = calendar.dateComponents([.era, .year, .month], from: date)
        return calendar.date(from: components) ?? calendar.startOfDay(for: date)
    }

    public static func startOfYear(
        containing date: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> Date {
        let components = calendar.dateComponents([.era, .year], from: date)
        return calendar.date(from: components) ?? startOfMonth(containing: date, calendar: calendar)
    }

    public static func movingMonth(
        from date: Date,
        by offset: Int,
        calendar: Calendar = .autoupdatingCurrent
    ) -> Date {
        let sourceDay = calendar.component(.day, from: date)
        let sourceMonth = startOfMonth(containing: date, calendar: calendar)
        guard let targetMonth = calendar.date(byAdding: .month, value: offset, to: sourceMonth),
              let dayRange = calendar.range(of: .day, in: .month, for: targetMonth)
        else {
            return date
        }

        var components = calendar.dateComponents([.era, .year, .month], from: targetMonth)
        components.day = min(sourceDay, dayRange.count)
        return calendar.date(from: components) ?? targetMonth
    }

    public static func movingYear(
        from date: Date,
        by offset: Int,
        calendar: Calendar = .autoupdatingCurrent
    ) -> Date {
        let sourceComponents = calendar.dateComponents([.era, .year, .month, .day], from: date)
        guard let sourceYear = sourceComponents.year else {
            return date
        }

        var targetComponents = sourceComponents
        targetComponents.year = sourceYear + offset
        targetComponents.day = 1
        guard let targetMonth = calendar.date(from: targetComponents),
              let dayRange = calendar.range(of: .day, in: .month, for: targetMonth)
        else {
            return date
        }

        targetComponents.day = min(sourceComponents.day ?? 1, dayRange.count)
        return calendar.date(from: targetComponents) ?? targetMonth
    }
}

public struct CalendarGridBuilder {
    private let calendar: Calendar
    private let locale: Locale

    public init(
        calendar: Calendar = .autoupdatingCurrent,
        locale: Locale = .autoupdatingCurrent
    ) {
        self.calendar = calendar
        self.locale = locale
    }

    public func month(containing date: Date, today: Date = Date()) -> CalendarMonth {
        let components = calendar.dateComponents([.era, .year, .month], from: date)
        guard let monthStart = calendar.date(from: components),
              let dayRange = calendar.range(of: .day, in: .month, for: monthStart) else {
            preconditionFailure("Calendar cannot create a month grid for \(date)")
        }

        let firstWeekday = calendar.component(.weekday, from: monthStart)
        let leadingEmptyDays = (firstWeekday - calendar.firstWeekday + 7) % 7
        var cells = [CalendarDay?](repeating: nil, count: 42)

        for dayNumber in dayRange {
            guard let dayDate = calendar.date(
                byAdding: .day,
                value: dayNumber - 1,
                to: monthStart
            ) else {
                continue
            }

            cells[leadingEmptyDays + dayNumber - 1] = CalendarDay(
                date: dayDate,
                number: dayNumber,
                isToday: calendar.isDate(dayDate, inSameDayAs: today),
                isWeekend: calendar.isDateInWeekend(dayDate)
            )
        }

        let weeks = stride(from: 0, to: cells.count, by: 7).map {
            Array(cells[$0 ..< ($0 + 7)])
        }
        let monthComponents = calendar.dateComponents([.year, .month], from: monthStart)

        return CalendarMonth(
            startDate: monthStart,
            year: monthComponents.year ?? 0,
            month: monthComponents.month ?? 0,
            title: formatted(monthStart, template: "yMMMM"),
            weekdaySymbols: orderedWeekdaySymbols(),
            weeks: weeks
        )
    }

    public func year(containing date: Date, today: Date = Date()) -> CalendarYear {
        let components = calendar.dateComponents([.era, .year], from: date)
        guard let yearStart = calendar.date(from: components) else {
            preconditionFailure("Calendar cannot create a year grid for \(date)")
        }

        let monthRange = calendar.range(of: .month, in: .year, for: yearStart) ?? 1..<13
        let months = monthRange.compactMap { monthNumber -> CalendarMonth? in
            guard let monthDate = calendar.date(
                from: DateComponents(
                    era: components.era,
                    year: components.year,
                    month: monthNumber,
                    day: 1
                )
            ) else {
                return nil
            }

            return month(containing: monthDate, today: today)
        }

        return CalendarYear(
            startDate: yearStart,
            year: components.year ?? 0,
            title: formatted(yearStart, template: "y"),
            months: months
        )
    }

    private func orderedWeekdaySymbols() -> [String] {
        let formatter = configuredFormatter()
        let localizedSymbols = formatter.veryShortStandaloneWeekdaySymbols ?? []
        let sundayFirstSymbols = localizedSymbols.count == 7
            ? localizedSymbols
            : ["日", "一", "二", "三", "四", "五", "六"]
        let startIndex = min(max(calendar.firstWeekday - 1, 0), 6)

        return Array(sundayFirstSymbols[startIndex...])
            + Array(sundayFirstSymbols[..<startIndex])
    }

    private func formatted(_ date: Date, template: String) -> String {
        let formatter = configuredFormatter()
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }

    private func configuredFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone
        return formatter
    }
}

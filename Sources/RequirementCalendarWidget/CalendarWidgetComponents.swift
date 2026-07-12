#if canImport(RequirementCalendarCore)
import RequirementCalendarCore
#endif
import SwiftUI

struct FullMonthGrid: View {
    let month: CalendarMonth

    var body: some View {
        GeometryReader { geometry in
            let rowHeight = geometry.size.height / 7
            let headerFontSize = min(13, max(8, rowHeight * 0.34))

            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    ForEach(Array(month.weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                        Text(symbol)
                            .font(.system(size: headerFontSize, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(height: rowHeight)

                ForEach(Array(month.weeks.enumerated()), id: \.offset) { _, week in
                    HStack(spacing: 0) {
                        ForEach(Array(week.enumerated()), id: \.offset) { _, day in
                            CalendarDayCell(day: day, compact: false)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .frame(height: rowHeight)
                }
            }
        }
    }
}

struct MiniMonthGrid: View {
    let month: CalendarMonth

    var body: some View {
        GeometryReader { geometry in
            let rowHeight = geometry.size.height / 6

            VStack(spacing: 0) {
                ForEach(Array(month.weeks.enumerated()), id: \.offset) { _, week in
                    HStack(spacing: 0) {
                        ForEach(Array(week.enumerated()), id: \.offset) { _, day in
                            CalendarDayCell(day: day, compact: true)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .frame(height: rowHeight)
                }
            }
        }
    }
}

private struct CalendarDayCell: View {
    let day: CalendarDay?
    let compact: Bool

    var body: some View {
        GeometryReader { geometry in
            let minimumLength = min(geometry.size.width, geometry.size.height)
            let circleSize = minimumLength * (compact ? 0.9 : 0.76)
            let fontSize = compact
                ? min(8, max(4.5, minimumLength * 0.55))
                : min(18, max(9, minimumLength * 0.46))

            ZStack {
                if let day {
                    if day.isToday {
                        Circle()
                            .fill(Color.red)
                            .frame(width: circleSize, height: circleSize)
                    }

                    Text(String(day.number))
                        .font(
                            .system(
                                size: fontSize,
                                weight: day.isToday ? .bold : .medium,
                                design: .rounded
                            )
                        )
                        .foregroundStyle(foregroundStyle(for: day))
                        .minimumScaleFactor(0.7)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }

    private func foregroundStyle(for day: CalendarDay) -> Color {
        if day.isToday {
            return .white
        }

        return day.isWeekend ? .red.opacity(0.76) : .primary
    }
}

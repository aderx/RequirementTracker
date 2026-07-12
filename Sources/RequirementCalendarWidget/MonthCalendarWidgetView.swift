#if canImport(RequirementCalendarCore)
import RequirementCalendarCore
#endif
import SwiftUI
import WidgetKit

@available(macOS 14.0, *)
struct MonthCalendarWidgetView: View {
    @Environment(\.widgetFamily) private var family

    let entry: CalendarWidgetEntry

    private var month: CalendarMonth {
        CalendarWidgetEnvironment.builder.month(containing: entry.date, today: entry.date)
    }

    var body: some View {
        if family == .systemExtraLarge {
            extraLargeLayout
        } else {
            largeLayout
        }
    }

    private var largeLayout: some View {
        VStack(alignment: .leading, spacing: 8) {
            monthHeader
            FullMonthGrid(month: month)
        }
    }

    private var extraLargeLayout: some View {
        GeometryReader { geometry in
            HStack(spacing: 18) {
                todaySummary
                    .frame(width: max(150, geometry.size.width * 0.28))

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    monthHeader
                    FullMonthGrid(month: month)
                }
            }
        }
    }

    private var monthHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text("\(month.month)月")
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(.red)

            // WidgetKit may localize interpolated integers with grouping separators.
            // The calendar year is an identifier, so render it verbatim as four digits.
            Text(verbatim: CalendarDisplayText.year(month.year))
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)
        }
    }

    private var todaySummary: some View {
        let calendar = CalendarWidgetEnvironment.calendar
        let day = calendar.component(.day, from: entry.date)

        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(CalendarWidgetEnvironment.weekdayName(for: entry.date))
                    .foregroundStyle(.red)
                Text("\(month.month)月")
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 17, weight: .bold, design: .rounded))

            Text(String(day))
                .font(.system(size: 88, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
                .minimumScaleFactor(0.55)
                .lineLimit(1)

            Spacer(minLength: 2)

            Text(month.title)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
        }
    }
}

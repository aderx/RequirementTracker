#if canImport(RequirementCalendarCore)
import RequirementCalendarCore
#endif
import SwiftUI
import WidgetKit

@available(macOS 14.0, *)
struct YearCalendarWidgetView: View {
    @Environment(\.widgetFamily) private var family

    let entry: CalendarWidgetEntry

    private var year: CalendarYear {
        CalendarWidgetEnvironment.builder.year(containing: entry.date, today: entry.date)
    }

    private var currentMonth: Int {
        CalendarWidgetEnvironment.calendar.component(.month, from: entry.date)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: family == .systemExtraLarge ? 8 : 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: CalendarDisplayText.year(year.year))
                    .font(
                        .system(
                            size: family == .systemExtraLarge ? 19 : 16,
                            weight: .bold,
                            design: .rounded
                        )
                    )
                    .foregroundStyle(.red)

                Spacer()

                Text("全年")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            GeometryReader { geometry in
                let columnCount = family == .systemExtraLarge ? 4 : 3
                let rowCount = family == .systemExtraLarge ? 3 : 4
                let spacing: CGFloat = family == .systemExtraLarge ? 8 : 5
                let cellHeight = (
                    geometry.size.height - spacing * CGFloat(rowCount - 1)
                ) / CGFloat(rowCount)
                let columns = Array(
                    repeating: GridItem(.flexible(), spacing: spacing),
                    count: columnCount
                )

                LazyVGrid(columns: columns, spacing: spacing) {
                    ForEach(year.months, id: \.month) { month in
                        MiniMonthView(
                            month: month,
                            isCurrentMonth: month.month == currentMonth,
                            extraLarge: family == .systemExtraLarge
                        )
                        .frame(height: cellHeight)
                    }
                }
            }
        }
    }
}

private struct MiniMonthView: View {
    let month: CalendarMonth
    let isCurrentMonth: Bool
    let extraLarge: Bool

    var body: some View {
        VStack(spacing: extraLarge ? 3 : 1) {
            Text("\(month.month)月")
                .font(
                    .system(
                        size: extraLarge ? 10 : 8,
                        weight: .bold,
                        design: .rounded
                    )
                )
                .foregroundStyle(isCurrentMonth ? .red : .primary)

            MiniMonthGrid(month: month)
        }
        .padding(.horizontal, extraLarge ? 4 : 2)
        .padding(.vertical, extraLarge ? 3 : 1)
        .background(
            isCurrentMonth ? Color.red.opacity(0.07) : Color.clear,
            in: RoundedRectangle(cornerRadius: extraLarge ? 8 : 5, style: .continuous)
        )
    }
}

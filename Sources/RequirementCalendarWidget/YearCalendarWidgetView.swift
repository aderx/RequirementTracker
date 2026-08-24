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
        CalendarWidgetEnvironment.builder.year(
            containing: entry.state.displayYear,
            today: entry.date
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: family == .systemExtraLarge ? 8 : 5) {
            HStack(alignment: .firstTextBaseline) {
                Button(intent: ChangeCalendarYearIntent(offset: -1)) {
                    navigationIcon("chevron.left")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("上一年")

                Text(verbatim: CalendarDisplayText.year(year.year))
                    .font(
                        .system(
                            size: family == .systemExtraLarge ? 19 : 16,
                            weight: .bold,
                            design: .rounded
                        )
                    )
                    .foregroundStyle(.red)

                if CalendarWidgetEnvironment.isDevelopment {
                    CalendarWidgetDevelopmentBadge()
                }

                Button(intent: ChangeCalendarYearIntent(offset: 1)) {
                    navigationIcon("chevron.right")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("下一年")

                Spacer(minLength: 4)

                Button(intent: ReturnYearToTodayIntent()) {
                    Text("今年")
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.red)
                        .padding(.horizontal, 7)
                        .frame(height: 22)
                        .background(Color.red.opacity(0.09), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("回到今年")
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
                            isCurrentMonth: CalendarWidgetEnvironment.calendar.isDate(
                                month.startDate,
                                equalTo: entry.date,
                                toGranularity: .month
                            ),
                            extraLarge: family == .systemExtraLarge,
                            events: entry.events
                        )
                        .frame(height: cellHeight)
                    }
                }
            }
        }
    }

    private func navigationIcon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.secondary)
            .frame(width: 20, height: 20)
            .background(Color.primary.opacity(0.045), in: Circle())
    }
}

private struct MiniMonthView: View {
    let month: CalendarMonth
    let isCurrentMonth: Bool
    let extraLarge: Bool
    let events: CalendarEventSnapshot

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

            MiniMonthGrid(month: month, events: events)
        }
        .padding(.horizontal, extraLarge ? 4 : 2)
        .padding(.vertical, extraLarge ? 3 : 1)
        .background(
            isCurrentMonth ? Color.red.opacity(0.07) : Color.clear,
            in: RoundedRectangle(cornerRadius: extraLarge ? 8 : 5, style: .continuous)
        )
    }
}

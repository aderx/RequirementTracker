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
        CalendarWidgetEnvironment.builder.month(
            containing: entry.state.displayMonth,
            today: entry.date
        )
    }

    var body: some View {
        if family == .systemExtraLarge {
            extraLargeLayout
        } else {
            largeLayout
        }
    }

    private var largeLayout: some View {
        GeometryReader { geometry in
            let headerHeight: CGFloat = 26
            let spacing: CGFloat = 7
            let minimumDetailHeight: CGFloat = 56
            let gridRowCount = CGFloat(month.visibleWeeks.count + 1)
            let availableGridHeight = max(
                0,
                geometry.size.height - headerHeight - minimumDetailHeight - spacing * 2
            )
            let gridHeight = min(gridRowCount * 34, availableGridHeight)

            VStack(alignment: .leading, spacing: spacing) {
                monthHeader
                    .frame(height: headerHeight)

                FullMonthGrid(
                    month: month,
                    selectedDate: entry.state.selectedDate,
                    events: entry.events
                )
                .frame(height: gridHeight)
                .contentTransition(.identity)

                SelectedDayAgenda(
                    selectedDate: entry.state.selectedDate,
                    events: entry.events,
                    maximumEvents: 2
                )
                .frame(maxHeight: .infinity)
                .contentTransition(.identity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var extraLargeLayout: some View {
        GeometryReader { geometry in
            HStack(spacing: 16) {
                selectedDaySummary
                    .frame(width: max(158, geometry.size.width * 0.29))

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    monthHeader
                        .frame(height: 28)

                    FullMonthGrid(
                        month: month,
                        selectedDate: entry.state.selectedDate,
                        events: entry.events
                    )
                    .contentTransition(.identity)
                }
            }
        }
    }

    private var monthHeader: some View {
        HStack(alignment: .center, spacing: 5) {
            Button(intent: ChangeCalendarMonthIntent(offset: -1)) {
                navigationIcon("chevron.left")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("上个月")

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(month.month)月")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(.red)

                // WidgetKit may localize interpolated integers with grouping separators.
                // The calendar year is an identifier, so render it verbatim as four digits.
                Text(verbatim: CalendarDisplayText.year(month.year))
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            Button(intent: ChangeCalendarMonthIntent(offset: 1)) {
                navigationIcon("chevron.right")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("下个月")

            Spacer(minLength: 4)

            Button(intent: ReturnMonthToTodayIntent()) {
                Text("回到今天")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.red)
                    .padding(.horizontal, 7)
                    .frame(height: 22)
                    .background(Color.red.opacity(0.09), in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("回到今天")
        }
    }

    private var selectedDaySummary: some View {
        let calendar = CalendarWidgetEnvironment.calendar
        let selectedDate = entry.state.selectedDate
        let day = calendar.component(.day, from: selectedDate)
        let selectedMonth = calendar.component(.month, from: selectedDate)

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(CalendarWidgetEnvironment.weekdayName(for: selectedDate))
                    .foregroundStyle(.red)
                Text("\(selectedMonth)月")
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 16, weight: .bold, design: .rounded))

            Text(String(day))
                .font(.system(size: 68, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
                .minimumScaleFactor(0.55)
                .lineLimit(1)

            SelectedDayAgenda(
                selectedDate: selectedDate,
                events: entry.events,
                maximumEvents: 4
            )
            .contentTransition(.identity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func navigationIcon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.secondary)
            .frame(width: 22, height: 22)
            .background(Color.primary.opacity(0.045), in: Circle())
    }
}

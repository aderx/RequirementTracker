#if canImport(RequirementCalendarCore)
import RequirementCalendarCore
#endif
import SwiftUI

struct FullMonthGrid: View {
    let month: CalendarMonth
    let selectedDate: Date
    let events: CalendarEventSnapshot

    var body: some View {
        GeometryReader { geometry in
            let weeks = month.visibleWeeks
            let rowHeight = geometry.size.height / CGFloat(weeks.count + 1)
            let headerFontSize = min(12, max(8, rowHeight * 0.32))

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

                ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                    HStack(spacing: 0) {
                        ForEach(Array(week.enumerated()), id: \.offset) { _, day in
                            CalendarDayButton(
                                day: day,
                                selectedDate: selectedDate,
                                events: events
                            )
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
    let events: CalendarEventSnapshot

    var body: some View {
        GeometryReader { geometry in
            let rowHeight = geometry.size.height / 6

            VStack(spacing: 0) {
                ForEach(Array(month.weeks.enumerated()), id: \.offset) { _, week in
                    HStack(spacing: 0) {
                        ForEach(Array(week.enumerated()), id: \.offset) { _, day in
                            CalendarDayCell(
                                day: day,
                                compact: true,
                                isSelected: false,
                                events: events
                            )
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .frame(height: rowHeight)
                }
            }
        }
    }
}

struct SelectedDayAgenda: View {
    let selectedDate: Date
    let events: CalendarEventSnapshot
    let maximumEvents: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(CalendarWidgetEnvironment.selectedDateTitle(for: selectedDate))
                    .font(.system(size: 10.5, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer(minLength: 4)

                if events.accessState == .fullAccess, !events.selectedDayEvents.isEmpty {
                    Text("\(events.selectedDayEvents.count) 项")
                        .font(.system(size: 7.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                }

                if let detailURL = CalendarWidgetEnvironment.calendarDetailURL(for: selectedDate) {
                    Link(destination: detailURL) {
                        HStack(spacing: 2) {
                            Text("打开详情")
                            Image(systemName: "arrow.up.right")
                        }
                        .font(.system(size: 7.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.blue)
                        .padding(.horizontal, 6)
                        .frame(height: 18)
                        .background(Color.blue.opacity(0.08), in: Capsule())
                        .contentShape(Capsule())
                    }
                    .accessibilityLabel("在系统日历中打开这一天")
                }
            }

            agendaContent
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    @ViewBuilder
    private var agendaContent: some View {
        switch events.accessState {
        case .fullAccess:
            if events.selectedDayEvents.isEmpty {
                Label("暂无节假日或日程", systemImage: "calendar.badge.checkmark")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(events.selectedDayEvents.prefix(maximumEvents))) { event in
                    HStack(spacing: 5) {
                        Circle()
                            .fill(event.isHoliday ? Color.red : Color.blue)
                            .frame(width: 4, height: 4)

                        Text(eventTime(event))
                            .font(.system(size: 8, weight: .semibold, design: .rounded))
                            .foregroundStyle(event.isHoliday ? Color.red : Color.secondary)
                            .frame(width: 28, alignment: .leading)

                        Text(event.title)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        Spacer(minLength: 0)
                    }
                }

                if events.selectedDayEvents.count > maximumEvents {
                    Text("另有 \(events.selectedDayEvents.count - maximumEvents) 项")
                        .font(.system(size: 7.5, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        case .notDetermined:
            Label("请在需求记录设置中允许日历访问", systemImage: "calendar.badge.exclamationmark")
                .font(.system(size: 8.5, weight: .medium))
                .foregroundStyle(.secondary)
        case .denied:
            Label("日历访问已关闭，可在设置中重新开启", systemImage: "lock")
                .font(.system(size: 8.5, weight: .medium))
                .foregroundStyle(.secondary)
        case .unavailable:
            Label("当前无法读取系统日历", systemImage: "calendar")
                .font(.system(size: 8.5, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    private func eventTime(_ event: CalendarWidgetEvent) -> String {
        if event.isHoliday {
            return "节假"
        }
        if event.isAllDay {
            return "全天"
        }
        return CalendarWidgetEnvironment.eventTime(for: event.startDate)
    }
}

private struct CalendarDayButton: View {
    let day: CalendarDay?
    let selectedDate: Date
    let events: CalendarEventSnapshot

    var body: some View {
        if let day {
            Button(intent: SelectCalendarDateIntent(date: day.date)) {
                CalendarDayCell(
                    day: day,
                    compact: false,
                    isSelected: CalendarWidgetEnvironment.calendar.isDate(
                        day.date,
                        inSameDayAs: selectedDate
                    ),
                    events: events
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.clear)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel(CalendarWidgetEnvironment.selectedDateTitle(for: day.date))
        } else {
            Color.clear
        }
    }
}

private struct CalendarDayCell: View {
    let day: CalendarDay?
    let compact: Bool
    let isSelected: Bool
    let events: CalendarEventSnapshot

    var body: some View {
        GeometryReader { geometry in
            let minimumLength = min(geometry.size.width, geometry.size.height)
            let circleSize = minimumLength * (compact ? 0.82 : (isSelected ? 0.72 : 0.64))
            let fontSize = compact
                ? min(8, max(4.5, minimumLength * 0.52))
                : min(16, max(9, minimumLength * 0.42))

            if let day {
                ZStack {
                    if day.isToday {
                        Circle()
                            .fill(Color.red)
                            .frame(width: circleSize, height: circleSize)
                            .offset(y: compact ? 0 : -2.5)
                    } else if isSelected {
                        Circle()
                            .fill(Color.red.opacity(0.11))
                            .overlay {
                                Circle()
                                    .strokeBorder(Color.red.opacity(0.42), lineWidth: 1)
                            }
                            .frame(width: circleSize, height: circleSize)
                            .offset(y: -2.5)
                    }

                    Text(String(day.number))
                        .font(
                            .system(
                                size: fontSize,
                                weight: day.isToday || isSelected ? .bold : .medium,
                                design: .rounded
                            )
                        )
                        .foregroundStyle(foregroundStyle(for: day))
                        .minimumScaleFactor(0.7)
                        .offset(y: compact ? 0 : -2.5)

                    eventMarker(for: day, size: minimumLength)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .contentShape(Rectangle())
            }
        }
    }

    @ViewBuilder
    private func eventMarker(for day: CalendarDay, size: CGFloat) -> some View {
        if let holidayTitle = events.holidayTitle(on: day.date), !compact {
            Text(String(holidayTitle.prefix(4)))
                .font(.system(size: min(6.5, max(5, size * 0.17)), weight: .semibold))
                .foregroundStyle(Color.red.opacity(0.85))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 1)
        } else if events.hasEvent(on: day.date) {
            Circle()
                .fill(Color.blue.opacity(0.78))
                .frame(width: compact ? 1.7 : 3, height: compact ? 1.7 : 3)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, compact ? 0 : 2)
        }
    }

    private func foregroundStyle(for day: CalendarDay) -> Color {
        if day.isToday {
            return .white
        }
        if isSelected {
            return .red
        }
        return day.isWeekend ? .red.opacity(0.72) : .primary
    }
}

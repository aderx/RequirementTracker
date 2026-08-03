#if canImport(RequirementCalendarCore)
import RequirementCalendarCore
#endif
import SwiftUI

struct CalendarWidgetDevelopmentBadge: View {
    var body: some View {
        Text("开发版")
            .font(.system(size: 8, weight: .black, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .frame(height: 18)
            .background(Color.red, in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(Color.white.opacity(0.72), lineWidth: 0.8)
            }
            .accessibilityLabel("开发版小组件")
    }
}

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
    let page: Int

    private var pageSize: Int {
        max(1, maximumEvents)
    }

    private var pageCount: Int {
        max(1, (events.selectedDayEvents.count + pageSize - 1) / pageSize)
    }

    private var visiblePage: Int {
        min(max(0, page), pageCount - 1)
    }

    private var visibleEvents: [CalendarWidgetEvent] {
        Array(
            events.selectedDayEvents
                .dropFirst(visiblePage * pageSize)
                .prefix(pageSize)
        )
    }

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
                            Text("详情")
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
                HStack(alignment: .top, spacing: 4) {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(visibleEvents) { event in
                            HStack(spacing: 5) {
                                Circle()
                                    .fill(event.isHoliday ? Color.red : Color.blue)
                                    .frame(width: 4, height: 4)

                                Text(eventTime(event))
                                    .font(.system(size: 8, weight: .semibold, design: .rounded))
                                    .foregroundStyle(event.isHoliday ? Color.red : Color.secondary)
                                    .frame(
                                        width: event.isHoliday || event.isAllDay ? 28 : 67,
                                        alignment: .leading
                                    )

                                Text(event.title)
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)

                                Spacer(minLength: 0)
                            }
                        }
                    }

                    if pageCount > 1 {
                        agendaPageControls
                    }
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

    private var agendaPageControls: some View {
        VStack(spacing: 3) {
            Button(intent: ChangeSelectedDayAgendaPageIntent(page: visiblePage - 1)) {
                agendaPageIcon("chevron.up", enabled: visiblePage > 0)
            }
            .buttonStyle(.plain)
            .disabled(visiblePage == 0)
            .accessibilityLabel("上一页日程")

            Button(intent: ChangeSelectedDayAgendaPageIntent(page: visiblePage + 1)) {
                agendaPageIcon("chevron.down", enabled: visiblePage + 1 < pageCount)
            }
            .buttonStyle(.plain)
            .disabled(visiblePage + 1 >= pageCount)
            .accessibilityLabel("下一页日程")
        }
    }

    private func agendaPageIcon(_ systemName: String, enabled: Bool) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 7, weight: .bold))
            .foregroundStyle(Color.blue.opacity(enabled ? 0.9 : 0.25))
            .frame(width: 17, height: 13)
            .background(
                Color.blue.opacity(enabled ? 0.08 : 0.035),
                in: RoundedRectangle(cornerRadius: 4, style: .continuous)
            )
    }

    private func eventTime(_ event: CalendarWidgetEvent) -> String {
        if event.isHoliday {
            return "节假"
        }
        if event.isAllDay {
            return "全天"
        }
        return "\(CalendarWidgetEnvironment.eventTime(for: event.startDate))"
            + "–"
            + CalendarWidgetEnvironment.eventTime(for: event.endDate)
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
            let cellMinimumLength = min(geometry.size.width, geometry.size.height)
            let markerHeight = compact
                ? CGFloat.zero
                : min(11, max(9, geometry.size.height * 0.22))
            let dateAreaHeight = max(
                0,
                geometry.size.height - markerHeight
            )
            let dateMinimumLength = min(
                geometry.size.width,
                compact ? geometry.size.height : dateAreaHeight
            )
            let circleSize = cellMinimumLength * (
                compact ? 0.82 : (isSelected ? 0.72 : 0.64)
            )
            let fontSize = compact
                ? min(8, max(4.5, dateMinimumLength * 0.52))
                : min(16, max(9, cellMinimumLength * 0.44))

            if let day {
                if compact {
                    ZStack {
                        dayNumber(
                            for: day,
                            circleSize: circleSize,
                            fontSize: fontSize
                        )
                        eventMarker(for: day, size: cellMinimumLength)
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .contentShape(Rectangle())
                } else {
                    ZStack(alignment: .topLeading) {
                        dayNumber(
                            for: day,
                            circleSize: circleSize,
                            fontSize: fontSize
                        )
                        .frame(width: geometry.size.width, height: dateAreaHeight)
                        .position(
                            x: geometry.size.width / 2,
                            y: dateAreaHeight / 2
                        )

                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .overlay(alignment: .bottom) {
                        // 节日/节气是独立浮层，不参与日期数字和选中圆的布局。
                        eventMarker(for: day, size: cellMinimumLength)
                            .frame(width: geometry.size.width, height: markerHeight)
                    }
                    .contentShape(Rectangle())
                }
            }
        }
    }

    private func dayNumber(
        for day: CalendarDay,
        circleSize: CGFloat,
        fontSize: CGFloat
    ) -> some View {
        ZStack {
            if day.isToday {
                Circle()
                    .fill(Color.red)
                    .frame(width: circleSize, height: circleSize)
            } else if isSelected {
                Circle()
                    .fill(Color.red.opacity(0.11))
                    .overlay {
                        Circle()
                            .strokeBorder(Color.red.opacity(0.42), lineWidth: 1)
                    }
                    .frame(width: circleSize, height: circleSize)
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
        }
    }

    @ViewBuilder
    private func eventMarker(for day: CalendarDay, size: CGFloat) -> some View {
        if let holidayTitle = events.holidayTitle(on: day.date), !compact {
            HStack(spacing: 1.5) {
                if events.hasScheduledEvent(on: day.date) {
                    Circle()
                        .fill(Color.blue.opacity(0.82))
                        .frame(width: 3, height: 3)
                }

                Text(String(holidayTitle.prefix(3)))
                    .font(.system(size: min(8.5, max(7, size * 0.23)), weight: .semibold))
                    .foregroundStyle(Color.red.opacity(0.88))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        } else if events.hasEvent(on: day.date) {
            Circle()
                .fill(Color.blue.opacity(0.78))
                .frame(width: compact ? 1.7 : 3, height: compact ? 1.7 : 3)
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment: compact ? .bottom : .center
                )
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

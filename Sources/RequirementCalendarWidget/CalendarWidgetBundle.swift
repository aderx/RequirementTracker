import Foundation
import SwiftUI
import WidgetKit

struct CalendarWidgetEntry: TimelineEntry {
    let date: Date
    let state: CalendarWidgetState
    let events: CalendarEventSnapshot
}

struct CalendarWidgetTimelineProvider: TimelineProvider {
    let scope: CalendarWidgetScope

    func placeholder(in context: Context) -> CalendarWidgetEntry {
        let now = Date()
        return CalendarWidgetEntry(
            date: now,
            state: CalendarWidgetStateStore.read(now: now),
            events: .preview(now: now)
        )
    }

    func getSnapshot(
        in context: Context,
        completion: @escaping (CalendarWidgetEntry) -> Void
    ) {
        let now = Date()
        let state = CalendarWidgetStateStore.read(now: now)
        completion(
            CalendarWidgetEntry(
                date: now,
                state: state,
                events: context.isPreview
                    ? .preview(now: state.selectedDate)
                    : CalendarWidgetEventLoader.load(for: state, scope: scope)
            )
        )
    }

    func getTimeline(
        in context: Context,
        completion: @escaping (Timeline<CalendarWidgetEntry>) -> Void
    ) {
        let now = Date()
        let calendar = Calendar.autoupdatingCurrent
        let state = CalendarWidgetStateStore.read(now: now)
        let nextMidnight = calendar.date(
            byAdding: .day,
            value: 1,
            to: calendar.startOfDay(for: now)
        ) ?? now.addingTimeInterval(24 * 60 * 60)
        let nextRefresh = min(nextMidnight, now.addingTimeInterval(15 * 60))
        completion(
            Timeline(
                entries: [
                    CalendarWidgetEntry(
                        date: now,
                        state: state,
                        events: CalendarWidgetEventLoader.load(for: state, scope: scope)
                    )
                ],
                policy: .after(nextRefresh)
            )
        )
    }
}

@available(macOS 14.0, *)
struct MonthCalendarWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: CalendarWidgetKind.month,
            provider: CalendarWidgetTimelineProvider(scope: .month)
        ) { entry in
            MonthCalendarWidgetView(entry: entry)
                .calendarWidgetBackground()
        }
        .configurationDisplayName("完整月历")
        .description("切换月份、选择日期，并查看系统日历中的节假日与日程。")
        .supportedFamilies([.systemLarge, .systemExtraLarge])
    }
}

@available(macOS 14.0, *)
struct YearCalendarWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: CalendarWidgetKind.year,
            provider: CalendarWidgetTimelineProvider(scope: .year)
        ) { entry in
            YearCalendarWidgetView(entry: entry)
                .calendarWidgetBackground()
        }
        .configurationDisplayName("全年日历")
        .description("切换年份，并在全年视图中查看有日程的日期。")
        .supportedFamilies([.systemLarge, .systemExtraLarge])
    }
}

@main
@available(macOS 14.0, *)
struct RequirementCalendarWidgetBundle: WidgetBundle {
    var body: some Widget {
        MonthCalendarWidget()
        YearCalendarWidget()
    }
}

private extension View {
    @ViewBuilder
    func calendarWidgetBackground() -> some View {
        if #available(macOS 14.0, *) {
            containerBackground(for: .widget) {
                Color.clear
            }
        } else {
            background(Color.clear)
        }
    }
}

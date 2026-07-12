import Foundation
import SwiftUI
import WidgetKit

struct CalendarWidgetEntry: TimelineEntry {
    let date: Date
}

struct CalendarWidgetTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> CalendarWidgetEntry {
        CalendarWidgetEntry(date: Date())
    }

    func getSnapshot(
        in context: Context,
        completion: @escaping (CalendarWidgetEntry) -> Void
    ) {
        completion(CalendarWidgetEntry(date: Date()))
    }

    func getTimeline(
        in context: Context,
        completion: @escaping (Timeline<CalendarWidgetEntry>) -> Void
    ) {
        let now = Date()
        let calendar = Calendar.autoupdatingCurrent
        let nextMidnight = calendar.date(
            byAdding: .day,
            value: 1,
            to: calendar.startOfDay(for: now)
        ) ?? now.addingTimeInterval(24 * 60 * 60)
        completion(
            Timeline(
                entries: [CalendarWidgetEntry(date: now)],
                policy: .after(nextMidnight)
            )
        )
    }
}

@available(macOS 14.0, *)
struct MonthCalendarWidget: Widget {
    private let kind = "com.xfu-work.RequirementTracker.calendar.month"

    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: kind,
            provider: CalendarWidgetTimelineProvider()
        ) { entry in
            MonthCalendarWidgetView(entry: entry)
                .calendarWidgetBackground()
        }
        .configurationDisplayName("完整月历")
        .description("用大尺寸卡片显示本月的完整日期，并高亮今天和周末。")
        .supportedFamilies([.systemLarge, .systemExtraLarge])
    }
}

@available(macOS 14.0, *)
struct YearCalendarWidget: Widget {
    private let kind = "com.xfu-work.RequirementTracker.calendar.year"

    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: kind,
            provider: CalendarWidgetTimelineProvider()
        ) { entry in
            YearCalendarWidgetView(entry: entry)
                .calendarWidgetBackground()
        }
        .configurationDisplayName("全年日历")
        .description("在一张大尺寸卡片中查看今年的 12 个月。")
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

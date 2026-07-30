import AppIntents
import Foundation

struct SelectCalendarDateIntent: AppIntent {
    static let title: LocalizedStringResource = "选择日期"
    static let openAppWhenRun = false

    @Parameter(title: "日期")
    var date: Date

    init() {}

    init(date: Date) {
        self.date = date
    }

    func perform() async throws -> some IntentResult {
        CalendarWidgetStateStore.selectDate(date)
        return .result()
    }
}

struct ChangeCalendarMonthIntent: AppIntent {
    static let title: LocalizedStringResource = "切换月份"
    static let openAppWhenRun = false

    @Parameter(title: "月份偏移")
    var offset: Int

    init() {}

    init(offset: Int) {
        self.offset = offset
    }

    func perform() async throws -> some IntentResult {
        CalendarWidgetStateStore.moveMonth(by: offset)
        return .result()
    }
}

struct ReturnMonthToTodayIntent: AppIntent {
    static let title: LocalizedStringResource = "回到今天"
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        CalendarWidgetStateStore.resetMonthToToday()
        return .result()
    }
}

struct ChangeSelectedDayAgendaPageIntent: AppIntent {
    static let title: LocalizedStringResource = "切换日程页"
    static let openAppWhenRun = false

    @Parameter(title: "页码")
    var page: Int

    init() {}

    init(page: Int) {
        self.page = page
    }

    func perform() async throws -> some IntentResult {
        CalendarWidgetStateStore.setAgendaPage(page)
        return .result()
    }
}

struct ChangeCalendarYearIntent: AppIntent {
    static let title: LocalizedStringResource = "切换年份"
    static let openAppWhenRun = false

    @Parameter(title: "年份偏移")
    var offset: Int

    init() {}

    init(offset: Int) {
        self.offset = offset
    }

    func perform() async throws -> some IntentResult {
        CalendarWidgetStateStore.moveYear(by: offset)
        return .result()
    }
}

struct ReturnYearToTodayIntent: AppIntent {
    static let title: LocalizedStringResource = "回到今年"
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        CalendarWidgetStateStore.resetYearToToday()
        return .result()
    }
}

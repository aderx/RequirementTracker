import Foundation

public enum RequirementStatusFilter: String, CaseIterable, Identifiable, Sendable {
    case pending
    case active
    case paused
    case completed
    case incomplete

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .incomplete:
            "未完成"
        case .pending:
            "待开发"
        case .active:
            "开发中"
        case .paused:
            "异常"
        case .completed:
            "已完成"
        }
    }

    public static var allCases: [RequirementStatusFilter] {
        [.incomplete, .active, .pending, .paused, .completed]
    }
}

public enum RequirementDateFilter: String, CaseIterable, Codable, Identifiable, Sendable {
    case all
    case today
    case thisWeek
    case thisMonth

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .all:
            "全部时间"
        case .today:
            "今天"
        case .thisWeek:
            "本周"
        case .thisMonth:
            "本月"
        }
    }
}

public struct RequirementDateRange: Equatable, Sendable {
    public var start: Date?
    public var end: Date?

    public init(start: Date? = nil, end: Date? = nil) {
        self.start = start
        self.end = end
    }

    public func contains(_ date: Date) -> Bool {
        if let start, date < start {
            return false
        }

        if let end, date >= end {
            return false
        }

        return true
    }
}

public enum RequirementDateDisplayFormatter {
    public static func dayDisplayText(for date: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy年M月d日"
        return formatter.string(from: date)
    }

    public static func displayText(for date: Date, calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.hour, .minute, .second, .nanosecond], from: date)
        let hasTime = (components.hour ?? 0) != 0
            || (components.minute ?? 0) != 0
            || (components.second ?? 0) != 0
            || (components.nanosecond ?? 0) != 0

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = hasTime ? "yyyy年M月d日 HH:mm" : "yyyy年M月d日"
        return formatter.string(from: date)
    }

    public static func shortDisplayText(for date: Date, calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.hour, .minute, .second, .nanosecond], from: date)
        let hasTime = (components.hour ?? 0) != 0
            || (components.minute ?? 0) != 0
            || (components.second ?? 0) != 0
            || (components.nanosecond ?? 0) != 0

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = hasTime ? "M月d日 HH:mm" : "M月d日"
        return formatter.string(from: date)
    }
}

public struct RequirementStats: Equatable, Sendable {
    public var total: Int
    public var active: Int
    public var pending: Int
    public var paused: Int
    public var completed: Int
    public var tested: Int
    public var merged: Int

    public init(
        total: Int = 0,
        active: Int = 0,
        pending: Int = 0,
        paused: Int = 0,
        completed: Int = 0,
        tested: Int = 0,
        merged: Int = 0
    ) {
        self.total = total
        self.active = active
        self.pending = pending
        self.paused = paused
        self.completed = completed
        self.tested = tested
        self.merged = merged
    }
}

public enum RequirementQuery {
    public static func filteredAndSorted(
        _ requirements: [Requirement],
        statusFilter: RequirementStatusFilter,
        dateFilter: RequirementDateFilter,
        calendar: Calendar = .current,
        referenceDate: Date = Date()
    ) -> [Requirement] {
        requirements
            .filter { requirement in
                matchesStatus(requirement, filter: statusFilter)
                    && matchesDate(requirement, filter: dateFilter, calendar: calendar, referenceDate: referenceDate)
            }
            .sorted(by: sortComparator)
    }

    public static func sorted(_ requirements: [Requirement]) -> [Requirement] {
        requirements.sorted(by: sortComparator)
    }

    public static func sorted(
        _ requirements: [Requirement],
        dateFilter: RequirementDateFilter,
        calendar: Calendar = .current,
        referenceDate: Date = Date()
    ) -> [Requirement] {
        requirements
            .filter {
                matchesDate($0, filter: dateFilter, calendar: calendar, referenceDate: referenceDate)
            }
            .sorted(by: sortComparator)
    }

    public static func sorted(
        _ requirements: [Requirement],
        dateRange: RequirementDateRange,
        calendar: Calendar = .current
    ) -> [Requirement] {
        requirements
            .filter {
                matchesDate($0, range: dateRange, calendar: calendar)
            }
            .sorted(by: sortComparator)
    }

    public static func stats(
        for requirements: [Requirement],
        dateFilter: RequirementDateFilter,
        calendar: Calendar = .current,
        referenceDate: Date = Date()
    ) -> RequirementStats {
        let scoped = requirements.filter {
            matchesDate($0, filter: dateFilter, calendar: calendar, referenceDate: referenceDate)
        }

        return RequirementStats(
            total: scoped.count,
            active: scoped.filter(isActiveDevelopment).count,
            pending: scoped.filter { !$0.isMerged && $0.stage == .pending }.count,
            paused: scoped.filter(isExceptional).count,
            completed: scoped.filter(\.isMerged).count,
            tested: scoped.filter(\.isTested).count,
            merged: scoped.filter(\.isMerged).count
        )
    }

    public static func stats(
        for requirements: [Requirement],
        dateRange: RequirementDateRange,
        calendar: Calendar = .current
    ) -> RequirementStats {
        let scoped = requirements.filter {
            matchesDate($0, range: dateRange, calendar: calendar)
        }

        return RequirementStats(
            total: scoped.count,
            active: scoped.filter(isActiveDevelopment).count,
            pending: scoped.filter { !$0.isMerged && $0.stage == .pending }.count,
            paused: scoped.filter(isExceptional).count,
            completed: scoped.filter(\.isMerged).count,
            tested: scoped.filter(\.isTested).count,
            merged: scoped.filter(\.isMerged).count
        )
    }

    public static func completedThisWeek(
        in requirements: [Requirement],
        calendar: Calendar = .current,
        referenceDate: Date = Date()
    ) -> Int {
        requirements.filter { requirement in
            guard requirement.isMerged else {
                return false
            }

            let date = requirement.completedAt ?? requirement.updatedAt
            return calendar.isDate(date, equalTo: referenceDate, toGranularity: .weekOfYear)
        }
        .count
    }

    private static func matchesStatus(_ requirement: Requirement, filter: RequirementStatusFilter) -> Bool {
        switch filter {
        case .incomplete:
            !requirement.isMerged && requirement.stage != .stopped
        case .pending:
            !requirement.isMerged && requirement.stage == .pending
        case .active:
            isActiveDevelopment(requirement)
        case .paused:
            isExceptional(requirement)
        case .completed:
            requirement.isMerged
        }
    }

    private static func matchesDate(
        _ requirement: Requirement,
        filter: RequirementDateFilter,
        calendar: Calendar,
        referenceDate: Date
    ) -> Bool {
        switch filter {
        case .all:
            true
        case .today:
            calendar.isDate(requirement.activityDate, inSameDayAs: referenceDate)
        case .thisWeek:
            calendar.isDate(requirement.activityDate, equalTo: referenceDate, toGranularity: .weekOfYear)
        case .thisMonth:
            calendar.isDate(requirement.activityDate, equalTo: referenceDate, toGranularity: .month)
        }
    }

    private static func matchesDate(
        _ requirement: Requirement,
        range: RequirementDateRange,
        calendar: Calendar
    ) -> Bool {
        range.contains(requirement.activityDate)
    }

    private static func sortComparator(lhs: Requirement, rhs: Requirement) -> Bool {
        let leftRank = sortRank(lhs)
        let rightRank = sortRank(rhs)

        if leftRank != rightRank {
            return leftRank < rightRank
        }

        if lhs.isMerged {
            return (lhs.completedAt ?? lhs.updatedAt) > (rhs.completedAt ?? rhs.updatedAt)
        }

        if lhs.stage == .paused || lhs.stage == .stopped {
            return lhs.updatedAt > rhs.updatedAt
        }

        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt < rhs.createdAt
        }

        return lhs.jiraKey < rhs.jiraKey
    }

    private static func isActiveDevelopment(_ requirement: Requirement) -> Bool {
        !requirement.isMerged
            && requirement.stage != .pending
            && requirement.stage != .paused
            && requirement.stage != .stopped
    }

    private static func isExceptional(_ requirement: Requirement) -> Bool {
        !requirement.isMerged && (requirement.stage == .paused || requirement.stage == .stopped)
    }

    private static func sortRank(_ requirement: Requirement) -> Int {
        if isActiveDevelopment(requirement) {
            return 0
        }

        if !requirement.isMerged && requirement.stage == .pending {
            return 1
        }

        if isExceptional(requirement) {
            return 2
        }

        return 3
    }
}

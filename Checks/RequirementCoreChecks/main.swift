import Foundation
import RequirementCore

@discardableResult
func expect(_ condition: @autoclosure () -> Bool, _ message: String) -> Bool {
    if !condition() {
        print("FAIL: \(message)")
        exit(1)
    }

    return true
}

func requirement(
    _ key: String,
    stage: RequirementStage,
    isDone: Bool = false,
    isTested: Bool = false,
    isMerged: Bool = false,
    createdAt: Date,
    completedAt: Date? = nil
) -> Requirement {
    Requirement(
        jiraKey: key,
        jiraURL: "http://jira.zstack.io/browse/\(key)",
        stage: stage,
        isDone: isDone,
        isTested: isTested,
        isMerged: isMerged,
        createdAt: createdAt,
        updatedAt: completedAt ?? createdAt,
        completedAt: completedAt
    )
}

func makeDate(year: Int, month: Int, day: Int) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!

    return calendar.date(
        from: DateComponents(
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day
        )
    )!
}

let input = """
10. http://jira.zstack.io/browse/ZSTAC-70121
11. zston-4751
"""

expect(
    RequirementParser.jiraKeys(from: input) == ["ZSTAC-70121", "ZSTON-4751"],
    "Jira keys should be parsed and uppercased"
)
expect(
    RequirementParser.jiraURL(from: input, jiraKey: "ZSTAC-70121")
        == "http://jira.zstack.io/browse/ZSTAC-70121",
    "Jira URL should be preserved when it exists"
)

let parsedRequirements = RequirementParser.requirements(
    fromBulkInput: "ZSTAC-70121\nhttp://jira.zstack.io/browse/ZSTAC-70121\nZSTAC-86113"
)
expect(
    parsedRequirements.map(\.jiraKey) == ["ZSTAC-70121", "ZSTAC-86113"],
    "Bulk parsing should deduplicate Jira keys"
)

let onePerLineRequirements = RequirementParser.requirements(
    fromBulkInput: "ZSTAC-70121 ZSTAC-86113\nZSTON-4751"
)
expect(
    onePerLineRequirements.map(\.jiraKey) == ["ZSTAC-70121", "ZSTON-4751"],
    "Bulk parsing should keep one Jira key per line"
)

expect(
    RequirementParser.mrIdentifier(
        from: "http://gitlab.zstack.io/zstackio/zstack-ui-next/-/merge_requests/6247"
    ) == "!6247",
    "GitLab MR URL should expose !number"
)
expect(
    RequirementParser.mrIdentifier(from: "!6213") == "!6213",
    "Existing !number should be preserved"
)

expect(
    RequirementStatusFilter.allCases.map(\.title) == ["未完成", "开发中", "待开发", "异常", "已完成"],
    "Status tabs should show active development before pending work"
)

let base = makeDate(year: 2026, month: 6, day: 19)
let active = requirement("ZSTAC-3", stage: .active, createdAt: base)
let pending = requirement("ZSTAC-2", stage: .pending, createdAt: base.addingTimeInterval(10))
let paused = requirement("ZSTAC-4", stage: .paused, createdAt: base.addingTimeInterval(20))
let completedOlder = requirement(
    "ZSTAC-1",
    stage: .completed,
    isDone: true,
    createdAt: base,
    completedAt: base.addingTimeInterval(30)
)
let completedNewer = requirement(
    "ZSTAC-5",
    stage: .completed,
    isDone: true,
    createdAt: base,
    completedAt: base.addingTimeInterval(60)
)

let sorted = RequirementQuery.sorted([completedOlder, pending, completedNewer, paused, active])
expect(
    sorted.map(\.jiraKey) == ["ZSTAC-1", "ZSTAC-3", "ZSTAC-5", "ZSTAC-2", "ZSTAC-4"],
    "Sorting should keep non-merged development items first, then pending, then exceptional items"
)

var calendar = Calendar(identifier: .gregorian)
calendar.timeZone = TimeZone(secondsFromGMT: 0)!

let referenceDate = makeDate(year: 2026, month: 6, day: 19)
let thisWeek = requirement(
    "ZSTAC-1",
    stage: .completed,
    isDone: true,
    isTested: true,
    isMerged: true,
    createdAt: referenceDate,
    completedAt: referenceDate
)
let lastMonth = requirement(
    "ZSTAC-2",
    stage: .completed,
    isDone: true,
    createdAt: makeDate(year: 2026, month: 5, day: 19),
    completedAt: makeDate(year: 2026, month: 5, day: 19)
)

let stats = RequirementQuery.stats(
    for: [thisWeek, lastMonth],
    dateFilter: .thisMonth,
    calendar: calendar,
    referenceDate: referenceDate
)

expect(stats.total == 1, "This-month stats should only include current month")
expect(stats.completed == 1, "This-month completed count should be 1")
expect(stats.tested == 1, "This-month tested count should be 1")
expect(stats.merged == 1, "This-month merged count should be 1")
expect(
    RequirementQuery.completedThisWeek(
        in: [thisWeek, lastMonth],
        calendar: calendar,
        referenceDate: referenceDate
    ) == 1,
    "Completed-this-week count should use completed date"
)

print("RequirementCoreChecks passed")

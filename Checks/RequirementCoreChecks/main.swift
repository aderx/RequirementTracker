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

func makeDate(year: Int, month: Int, day: Int, hour: Int = 0, minute: Int = 0) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!

    return calendar.date(
        from: DateComponents(
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
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

let preciseDate = makeDate(year: 2026, month: 6, day: 19, hour: 15, minute: 42)
expect(
    RequirementDateDisplayFormatter.displayText(for: preciseDate, calendar: calendar) == "2026年6月19日 15:42",
    "Display formatter should include time when hour/minute are present"
)
expect(
    RequirementDateDisplayFormatter.dayDisplayText(for: preciseDate, calendar: calendar) == "2026年6月19日",
    "Day display formatter should never include time"
)
expect(
    RequirementDateDisplayFormatter.displayText(for: referenceDate, calendar: calendar) == "2026年6月19日",
    "Display formatter should show day only for midnight dates"
)

let range = RequirementDateRange(
    start: referenceDate,
    end: referenceDate.addingTimeInterval(86_400)
)
let inRange = requirement(
    "ZSTAC-9",
    stage: .pending,
    createdAt: referenceDate.addingTimeInterval(60)
)
let outOfRange = requirement(
    "ZSTAC-10",
    stage: .pending,
    createdAt: referenceDate.addingTimeInterval(172_800)
)
expect(
    RequirementQuery.sorted([inRange, outOfRange], dateRange: range, calendar: calendar).map(\.jiraKey) == ["ZSTAC-9"],
    "Custom range filtering should keep only requirements whose activity date is inside the range"
)

var mergeCandidate = requirement(
    "ZSTAC-11",
    stage: .completed,
    isDone: true,
    isTested: true,
    createdAt: referenceDate
)
expect(!mergeCandidate.hasMergeRequestURL, "Blank MR should not satisfy merge requirement")
mergeCandidate.mrURL = " http://gitlab.zstack.io/demo/-/merge_requests/1 "
expect(mergeCandidate.hasMergeRequestURL, "Non-blank MR should satisfy merge requirement")

var historyRequirement = requirement(
    "ZSTAC-12",
    stage: .pending,
    createdAt: referenceDate
)
historyRequirement.recordStatus(.done, at: referenceDate.addingTimeInterval(60))
historyRequirement.recordStatus(.tested, at: referenceDate.addingTimeInterval(120))
expect(
    historyRequirement.statusHistory.map(\.status) == [.pending, .done, .tested],
    "Status history should append new statuses after old statuses"
)

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

let validProject = RequirementScriptProject(
    name: " UI Next ",
    directoryPath: " /Users/dev/zstack-ui-next ",
    scripts: [
        RequirementScriptCommand(name: " Dev ", script: "pnpm dev"),
        RequirementScriptCommand(name: " Empty ", script: "   ")
    ]
)
let invalidProject = RequirementScriptProject(
    name: " Empty Scripts ",
    directoryPath: "/tmp/demo",
    scripts: [
        RequirementScriptCommand(name: "Noop", script: "")
    ]
)
let toolConfiguration = RequirementToolConfiguration(
    scriptProjects: [validProject, invalidProject],
    quickLinks: [
        RequirementQuickLink(name: " Jira ", url: " https://jira.zstack.io "),
        RequirementQuickLink(name: " Broken ", url: "notaurl")
    ]
)
expect(
    toolConfiguration.validScriptProjects.map(\.name) == ["UI Next"],
    "Tool configuration should expose only projects with valid directories and scripts"
)
expect(
    toolConfiguration.validScriptProjects.first?.validScripts.map(\.name) == ["Dev"],
    "Tool configuration should trim and expose only valid scripts"
)
expect(
    toolConfiguration.validQuickLinks.map(\.name) == ["Jira"],
    "Tool configuration should expose only valid links"
)

let launchScript = GhosttyAutomationScript.jxa(
    projectDirectory: "/Users/dev/zstack-ui-next",
    command: "echo \"hello\"\npnpm dev",
    knownWindowID: "project-window-1"
)
expect(
    launchScript.contains("Application(\"/Applications/Ghostty.app\")"),
    "Ghostty JXA should target the bundled Ghostty app path"
)
expect(
    launchScript.contains("initialWorkingDirectory: \"/Users/dev/zstack-ui-next\""),
    "Ghostty JXA should set the project working directory"
)
expect(
    launchScript.contains("initialInput: \"cd '/Users/dev/zstack-ui-next'\\necho \\\"hello\\\"\\npnpm dev\\n\""),
    "Ghostty JXA should enter the project directory before running multiline shell input"
)
expect(
    launchScript.contains("newTab") && launchScript.contains("newWindow"),
    "Ghostty JXA should support existing project windows and new windows"
)
expect(
    GhosttyAutomationScript.shellCommand(
        projectDirectory: "/Users/dev/project with spaces",
        command: "pnpm dev"
    ) == "cd '/Users/dev/project with spaces'\npnpm dev",
    "Ghostty fallback shell command should cd into project directories, including paths with spaces"
)
let openArguments = GhosttyAutomationScript.openArguments(
    projectDirectory: "/Users/dev/project with spaces",
    command: "pnpm dev"
)
expect(
    openArguments == [
        "-na",
        "/Applications/Ghostty.app",
        "--args",
        "--working-directory=/Users/dev/project with spaces",
        "--initial-command=shell:cd '/Users/dev/project with spaces'\npnpm dev"
    ],
    "Ghostty open fallback should pass one initial shell command, not split /bin/zsh arguments"
)

print("RequirementCoreChecks passed")

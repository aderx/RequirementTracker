import Foundation
import RequirementCalendarCore
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

let titledRequirementJSON = """
{
  "id": "00000000-0000-0000-0000-000000000001",
  "jiraKey": "ZSTAC-70121",
  "jiraURL": "http://jira.zstack.io/browse/ZSTAC-70121",
  "mrURL": "http://gitlab.zstack.io/demo/-/merge_requests/1",
  "title": "修复浏览器插件写入",
  "note": "",
  "pauseReason": "",
  "stage": "pending",
  "isDone": false,
  "isTested": false,
  "isMerged": false,
  "createdAt": "2026-06-19T00:00:00Z",
  "updatedAt": "2026-06-19T00:00:00Z",
  "statusHistory": []
}
""".data(using: .utf8)!
let legacyRequirementJSON = """
{
  "id": "00000000-0000-0000-0000-000000000002",
  "jiraKey": "ZSTAC-70122",
  "jiraURL": "http://jira.zstack.io/browse/ZSTAC-70122",
  "note": "",
  "pauseReason": "",
  "stage": "pending",
  "isDone": false,
  "isTested": false,
  "isMerged": false,
  "createdAt": "2026-06-19T00:00:00Z",
  "updatedAt": "2026-06-19T00:00:00Z",
  "statusHistory": []
}
""".data(using: .utf8)!
let requirementDecoder = JSONDecoder()
requirementDecoder.dateDecodingStrategy = .iso8601
let decodedTitledRequirement = try requirementDecoder.decode(Requirement.self, from: titledRequirementJSON)
let decodedLegacyRequirement = try requirementDecoder.decode(Requirement.self, from: legacyRequirementJSON)
expect(
    decodedTitledRequirement.title == "修复浏览器插件写入"
        && decodedLegacyRequirement.title.isEmpty,
    "Requirement should decode Jira title and default legacy records to blank title"
)
let requirementEncoder = JSONEncoder()
requirementEncoder.dateEncodingStrategy = .iso8601
let encodedTitledRequirement = String(
    data: try requirementEncoder.encode(decodedTitledRequirement),
    encoding: .utf8
) ?? ""
expect(
    encodedTitledRequirement.contains("\"title\":\"修复浏览器插件写入\""),
    "Requirement should encode Jira title back to JSON"
)
expect(
    decodedTitledRequirement.mrHistory.isEmpty
        && decodedTitledRequirement.allMRURLs == [
            "http://gitlab.zstack.io/demo/-/merge_requests/1"
        ],
    "Legacy single-MR records should decode with no history"
)
expect(
    !encodedTitledRequirement.contains("\"mrHistory\""),
    "Single-MR records should omit empty MR history"
)

var multiMRRequirement = decodedTitledRequirement
multiMRRequirement.recordMergeRequestURL(
    "http://gitlab.zstack.io/demo/-/merge_requests/2?diff_id=1#note_2"
)
expect(
    multiMRRequirement.mrURL == "http://gitlab.zstack.io/demo/-/merge_requests/2"
        && multiMRRequirement.mrHistory == [
            "http://gitlab.zstack.io/demo/-/merge_requests/1"
        ],
    "A new MR should become latest and move the old latest into history"
)

multiMRRequirement.recordMergeRequestURL(
    "http://gitlab.zstack.io/demo/-/merge_requests/1"
)
expect(
    multiMRRequirement.allMRURLs == [
        "http://gitlab.zstack.io/demo/-/merge_requests/2",
        "http://gitlab.zstack.io/demo/-/merge_requests/1"
    ],
    "Recording an existing historical MR should not duplicate or reorder it"
)

multiMRRequirement.recordMergeRequestURL(
    "http://gitlab.zstack.io/demo/-/merge_requests/3"
)
expect(
    multiMRRequirement.allMRURLs == [
        "http://gitlab.zstack.io/demo/-/merge_requests/3",
        "http://gitlab.zstack.io/demo/-/merge_requests/2",
        "http://gitlab.zstack.io/demo/-/merge_requests/1"
    ],
    "MR URLs should remain newest-first"
)

let encodedMultiMRRequirement = String(
    data: try requirementEncoder.encode(multiMRRequirement),
    encoding: .utf8
) ?? ""
expect(
    encodedMultiMRRequirement.contains("\"mrHistory\":[")
        && encodedMultiMRRequirement.contains("merge_requests\\/2")
        && encodedMultiMRRequirement.contains("merge_requests\\/1"),
    "Multiple-MR records should encode historical URLs"
)

multiMRRequirement.mrURL = nil
multiMRRequirement.normalizeMergeRequestURLs()
expect(
    multiMRRequirement.mrURL == "http://gitlab.zstack.io/demo/-/merge_requests/2"
        && multiMRRequirement.mrHistory == [
            "http://gitlab.zstack.io/demo/-/merge_requests/1"
        ],
    "Normalization should promote the newest history item when latest is empty"
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
    RequirementParser.normalizedURL(
        "http://jira.zstack.io/browse/ZSTAC-70121?filter=123#comment-1"
    ) == "http://jira.zstack.io/browse/ZSTAC-70121",
    "Requirement parser should strip query and fragment from Jira URLs"
)
expect(
    RequirementParser.normalizedURL(
        "http://gitlab.zstack.io/zstackio/zstack-ui-next/-/merge_requests/6247?diff_id=1#note_2"
    ) == "http://gitlab.zstack.io/zstackio/zstack-ui-next/-/merge_requests/6247",
    "Requirement parser should strip query and fragment from MR URLs"
)
expect(
    RequirementParser.jiraURL(
        from: "http://jira.zstack.io/browse/ZSTAC-70121?filter=123#comment-1",
        jiraKey: "ZSTAC-70121"
    ) == "http://jira.zstack.io/browse/ZSTAC-70121",
    "Jira URL extraction should store sanitized URLs"
)
expect(
    RequirementExternalUpdateNotification.name.rawValue == "com.aderx.requirementtracker.requirementsDidChange",
    "External writes should share a stable distributed notification name"
)
expect(
    RequirementNativeHostProtocol.currentVersion == 2
        && !RequirementNativeHostProtocol.isCompatible(nil)
        && !RequirementNativeHostProtocol.isCompatible(1)
        && RequirementNativeHostProtocol.isCompatible(2)
        && RequirementNativeHostProtocol.isCompatible(3),
    "Native Host protocol compatibility should reject missing or older versions"
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

var overviewCreatedNewest = requirement(
    "ZSTAC-101",
    stage: .active,
    createdAt: base.addingTimeInterval(300)
)
overviewCreatedNewest.updatedAt = base.addingTimeInterval(300)
var overviewUpdatedNewest = requirement(
    "ZSTAC-102",
    stage: .active,
    createdAt: base.addingTimeInterval(100)
)
overviewUpdatedNewest.updatedAt = base.addingTimeInterval(400)
var overviewMiddle = requirement(
    "ZSTAC-103",
    stage: .active,
    createdAt: base.addingTimeInterval(200)
)
overviewMiddle.updatedAt = base.addingTimeInterval(200)
let overviewSortInput = [overviewUpdatedNewest, overviewMiddle, overviewCreatedNewest]

expect(
    RequirementQuery.sortedForOverview(overviewSortInput, by: .createdAt).map(\.jiraKey)
        == ["ZSTAC-101", "ZSTAC-103", "ZSTAC-102"],
    "Overview should default to newest creation time first"
)
expect(
    RequirementQuery.sortedForOverview(overviewSortInput, by: .updatedAt).map(\.jiraKey)
        == ["ZSTAC-102", "ZSTAC-101", "ZSTAC-103"],
    "Overview should optionally sort by newest update time first"
)

let overviewStatusInput = [
    requirement("ZSTAC-201", stage: .pending, createdAt: base),
    requirement("ZSTAC-202", stage: .active, createdAt: base),
    requirement("ZSTAC-203", stage: .completed, isDone: true, createdAt: base),
    requirement("ZSTAC-204", stage: .completed, isDone: true, isTested: true, createdAt: base),
    requirement(
        "ZSTAC-205",
        stage: .completed,
        isDone: true,
        isTested: true,
        isMerged: true,
        createdAt: base
    ),
    requirement("ZSTAC-206", stage: .paused, createdAt: base),
    requirement("ZSTAC-207", stage: .stopped, createdAt: base)
]
let overviewStatusExpectations: [(RequirementTimelineStatus, String)] = [
    (.pending, "ZSTAC-201"),
    (.active, "ZSTAC-202"),
    (.done, "ZSTAC-203"),
    (.tested, "ZSTAC-204"),
    (.merged, "ZSTAC-205"),
    (.paused, "ZSTAC-206"),
    (.stopped, "ZSTAC-207")
]
for (status, jiraKey) in overviewStatusExpectations {
    expect(
        RequirementQuery.filteredForOverview(overviewStatusInput, status: status).map(\.jiraKey) == [jiraKey],
        "Overview status filter should keep only \(status.title) requirements"
    )
}
expect(
    RequirementQuery.filteredForOverview(overviewStatusInput, status: nil).map(\.jiraKey)
        == overviewStatusInput.map(\.jiraKey),
    "Overview all filter should clear status filtering"
)

var overviewMetadataA = requirement("ZSTAC-301", stage: .active, createdAt: base)
overviewMetadataA.issueType = " 改进 "
overviewMetadataA.priority = "P1"
overviewMetadataA.targetVersion = "5.5.28"
var overviewMetadataB = requirement("ZSTAC-302", stage: .active, createdAt: base)
overviewMetadataB.issueType = "故障"
overviewMetadataB.priority = "P0"
overviewMetadataB.targetVersion = "5.5.28"
var overviewMetadataC = requirement("ZSTAC-303", stage: .active, createdAt: base)
overviewMetadataC.issueType = "改进"
overviewMetadataC.priority = "P1"
overviewMetadataC.targetVersion = "5.5.38"
let overviewMetadataInput = [overviewMetadataA, overviewMetadataB, overviewMetadataC]
let overviewMetadataOptions = RequirementQuery.overviewMetadataOptions(for: overviewMetadataInput)

expect(
    overviewMetadataOptions.issueTypes == ["改进", "故障"]
        && overviewMetadataOptions.priorities == ["P0", "P1"]
        && overviewMetadataOptions.targetVersions == ["5.5.28", "5.5.38"],
    "Overview metadata options should trim, deduplicate, and sort values from all requirements"
)
expect(
    RequirementQuery.filteredForOverview(
        overviewMetadataInput,
        metadata: RequirementOverviewMetadataFilter(
            issueType: "改进",
            priority: "P1",
            targetVersion: "5.5.38"
        )
    ).map(\.jiraKey) == ["ZSTAC-303"],
    "Overview metadata filters should combine Jira type, priority, and version"
)
expect(
    RequirementQuery.filteredForOverview(
        overviewMetadataInput,
        metadata: RequirementOverviewMetadataFilter()
    ).map(\.jiraKey) == overviewMetadataInput.map(\.jiraKey),
    "Empty overview metadata filters should preserve all requirements"
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
expect(
    historyRequirement.statusHistoryNewestFirst.map(\.status) == [.tested, .done, .pending],
    "Overview status history should expose newest events first"
)

let directMergeCandidate = requirement(
    "ZSTAC-13",
    stage: .active,
    createdAt: referenceDate
)
let pausedDirectMergeCandidate = requirement(
    "ZSTAC-14",
    stage: .paused,
    createdAt: referenceDate
)
expect(
    directMergeCandidate.canMarkMergedDirectly && !pausedDirectMergeCandidate.canMarkMergedDirectly,
    "Only non-exceptional unfinished requirements should allow direct completion"
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
let reorderProjectA = RequirementScriptProject(name: "A", directoryPath: "/tmp/a")
let reorderProjectB = RequirementScriptProject(name: "B", directoryPath: "/tmp/b")
let reorderProjectC = RequirementScriptProject(name: "C", directoryPath: "/tmp/c")
var reorderedProjectConfiguration = RequirementToolConfiguration(
    scriptProjects: [reorderProjectA, reorderProjectB, reorderProjectC]
)
expect(
    reorderedProjectConfiguration.moveScriptProject(id: reorderProjectB.id, offset: -1)
        && reorderedProjectConfiguration.scriptProjects.map(\.name) == ["B", "A", "C"],
    "Script projects should support moving up in settings"
)
expect(
    !reorderedProjectConfiguration.moveScriptProject(id: reorderProjectB.id, offset: -1)
        && reorderedProjectConfiguration.scriptProjects.map(\.name) == ["B", "A", "C"],
    "Script project reordering should ignore out-of-range moves"
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
expect(
    toolConfiguration.baseSettings.panelFilters.selection(for: .completed).dateFilter == .all,
    "Tool configuration should default each status tab to all dates"
)
expect(
    toolConfiguration.baseSettings.panelStyle == .standard,
    "Tool configuration should default to the standard panel style"
)

var panelFilterConfiguration = RequirementPanelFilterConfiguration()
panelFilterConfiguration.setSelection(
    RequirementPanelDateSelection(dateFilter: .thisWeek),
    for: .active
)
expect(
    panelFilterConfiguration.selection(for: .active).dateFilter == .thisWeek
        && panelFilterConfiguration.selection(for: .pending).dateFilter == .all,
    "Panel filter configuration should keep independent date filters per status tab"
)

let legacySettingsJSON = """
{
  "quickLinks": [],
  "scriptProjects": []
}
""".data(using: .utf8)!
let legacyConfiguration = try JSONDecoder().decode(RequirementToolConfiguration.self, from: legacySettingsJSON)
expect(
    legacyConfiguration.baseSettings.panelStyle == .standard
        && legacyConfiguration.baseSettings.panelFilters.selection(for: .incomplete).dateFilter == .all,
    "Tool configuration should decode legacy settings without base settings"
)
let partialBaseSettingsJSON = """
{
  "baseSettings": {},
  "quickLinks": [],
  "scriptProjects": []
}
""".data(using: .utf8)!
let partialBaseSettingsConfiguration = try JSONDecoder().decode(
    RequirementToolConfiguration.self,
    from: partialBaseSettingsJSON
)
expect(
    partialBaseSettingsConfiguration.baseSettings.panelStyle == .standard
        && partialBaseSettingsConfiguration.baseSettings.panelFilters.selection(for: .active).dateFilter == .all,
    "Tool configuration should decode base settings without panel filters"
)
let modernPanelSettingsJSON = """
{
  "baseSettings": {
    "panelStyle": "modern"
  }
}
""".data(using: .utf8)!
let modernPanelConfiguration = try JSONDecoder().decode(
    RequirementToolConfiguration.self,
    from: modernPanelSettingsJSON
)
expect(
    modernPanelConfiguration.baseSettings.panelStyle == .modern,
    "Tool configuration should persist an explicitly selected panel style"
)
expect(
    RequirementPluginSettings().normalized.validMRHosts == ["gitlab.zstack.io"],
    "Plugin settings should default to the current GitLab host"
)
let pluginConfiguration = RequirementToolConfiguration(
    pluginSettings: RequirementPluginSettings(
        jiraBaseURL: " http://jira.zstack.io/browse?filter=1#hash ",
        mrHosts: [" gitlab.zstack.io ", " ", "http://gitlab.example.com/group/project/-/merge_requests/1?x=1"],
        chromeExtensionID: " abcdef "
    )
)
expect(
    pluginConfiguration.normalized.pluginSettings.jiraBaseURL == "http://jira.zstack.io/browse/"
        && pluginConfiguration.normalized.pluginSettings.validMRHosts == ["gitlab.zstack.io", "gitlab.example.com"]
        && pluginConfiguration.normalized.pluginSettings.chromeExtensionID == "abcdef",
    "Tool configuration should normalize plugin settings for the extension"
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
    launchScript.contains("existingWindow(\"project-window-1\")"),
    "Ghostty JXA should reuse the known project window by stable ID"
)
expect(
    launchScript.contains("waitAfterCommand: true"),
    "Ghostty JXA should keep the terminal open after the command exits"
)
expect(
    !launchScript.contains("--working-directory") && !launchScript.contains("--input"),
    "Ghostty JXA must not pass instance-level launch arguments that leak into user-opened tabs"
)
let freshWindowScript = GhosttyAutomationScript.jxa(
    projectDirectory: "/Users/dev/zstack-ui-next",
    command: "pnpm dev"
)
expect(
    freshWindowScript.contains("existingWindow(null)"),
    "Ghostty JXA without a known window should create a new window"
)
expect(
    GhosttyAutomationScript.shellCommand(
        projectDirectory: "/Users/dev/project with spaces",
        command: "pnpm dev"
    ) == "cd '/Users/dev/project with spaces'\npnpm dev",
    "Ghostty fallback shell command should cd into project directories, including paths with spaces"
)

let sortActiveOld = requirement("ZSTAC-9001", stage: .active, createdAt: makeDate(year: 2026, month: 7, day: 1))
let sortActiveNew = requirement("ZSTAC-9002", stage: .active, createdAt: makeDate(year: 2026, month: 7, day: 2))
let sortTested = requirement(
    "ZSTAC-9003",
    stage: .completed,
    isDone: true,
    isTested: true,
    createdAt: makeDate(year: 2026, month: 7, day: 1),
    completedAt: makeDate(year: 2026, month: 7, day: 3)
)
let sortPending = requirement("ZSTAC-9004", stage: .pending, createdAt: makeDate(year: 2026, month: 6, day: 30))
let sortInput = [sortTested, sortActiveNew, sortPending, sortActiveOld]

expect(
    RequirementQuery.filteredAndSorted(
        sortInput,
        statusFilter: .incomplete,
        dateFilter: .all,
        sortRules: RequirementTabSortConfiguration.defaultRules(for: .incomplete)
    ).map(\.jiraKey) == RequirementQuery.filteredAndSorted(
        sortInput,
        statusFilter: .incomplete,
        dateFilter: .all
    ).map(\.jiraKey),
    "Default tab sort rules should match the legacy incomplete ordering"
)

expect(
    RequirementQuery.filteredAndSorted(
        sortInput,
        statusFilter: .incomplete,
        dateFilter: .all,
        sortRules: [
            RequirementTabSortRule(status: .tested),
            RequirementTabSortRule(status: .active, ascending: false),
            RequirementTabSortRule(status: .pending),
            RequirementTabSortRule(status: .done),
            RequirementTabSortRule(status: .paused)
        ]
    ).map(\.jiraKey) == ["ZSTAC-9003", "ZSTAC-9002", "ZSTAC-9001", "ZSTAC-9004"],
    "Custom tab sort rules should reorder status groups and honor per-status direction"
)

var sortConfiguration = RequirementTabSortConfiguration()
sortConfiguration.setRules(
    [
        RequirementTabSortRule(status: .merged),
        RequirementTabSortRule(status: .tested)
    ],
    for: .incomplete
)
let normalizedIncompleteRules = sortConfiguration.rules(for: .incomplete)
expect(
    normalizedIncompleteRules.first?.status == .tested && normalizedIncompleteRules.count == 5,
    "Tab sort rules should drop foreign statuses and backfill missing ones"
)

var mondayFirstCalendar = Calendar(identifier: .gregorian)
mondayFirstCalendar.locale = Locale(identifier: "zh_Hans_CN")
mondayFirstCalendar.timeZone = TimeZone(secondsFromGMT: 0)!
mondayFirstCalendar.firstWeekday = 2
let mondayFirstGrid = CalendarGridBuilder(
    calendar: mondayFirstCalendar,
    locale: Locale(identifier: "zh_Hans_CN")
)
let june2026 = mondayFirstGrid.month(
    containing: makeDate(year: 2026, month: 6, day: 15),
    today: makeDate(year: 2026, month: 6, day: 19)
)
let juneCells = june2026.weeks.flatMap { $0 }
expect(
    june2026.weeks.count == 6
        && june2026.weeks.allSatisfy { $0.count == 7 }
        && juneCells[0]?.number == 1,
    "A month grid should always provide six complete weeks and honor Monday as the first weekday"
)
expect(
    june2026.weekdaySymbols == ["一", "二", "三", "四", "五", "六", "日"],
    "Weekday labels should follow the calendar first-weekday preference"
)
expect(
    juneCells.compactMap { $0 }.first(where: { $0.number == 19 })?.isToday == true,
    "The current day should be marked inside its month"
)
expect(
    juneCells.compactMap { $0 }.first(where: { $0.number == 20 })?.isWeekend == true
        && juneCells.compactMap { $0 }.first(where: { $0.number == 22 })?.isWeekend == false,
    "Weekend highlighting should come from Calendar rather than fixed columns"
)

var sundayFirstCalendar = mondayFirstCalendar
sundayFirstCalendar.firstWeekday = 1
let sundayFirstGrid = CalendarGridBuilder(
    calendar: sundayFirstCalendar,
    locale: Locale(identifier: "zh_Hans_CN")
)
let february2024 = sundayFirstGrid.month(
    containing: makeDate(year: 2024, month: 2, day: 10),
    today: makeDate(year: 2024, month: 2, day: 29)
)
let februaryCells = february2024.weeks.flatMap { $0 }
expect(
    februaryCells.prefix(4).allSatisfy { $0 == nil }
        && februaryCells[4]?.number == 1
        && februaryCells.compactMap { $0 }.last?.number == 29,
    "Leap February should align to Sunday-first columns and include February 29"
)

let year2026 = mondayFirstGrid.year(
    containing: makeDate(year: 2026, month: 7, day: 12),
    today: makeDate(year: 2026, month: 7, day: 12)
)
let highlightedYearDays = year2026.months
    .flatMap(\.weeks)
    .flatMap { $0 }
    .compactMap { $0 }
    .filter(\.isToday)
expect(
    year2026.year == 2026
        && year2026.months.map(\.month) == Array(1 ... 12)
        && highlightedYearDays.count == 1,
    "A Gregorian year grid should contain all 12 months and exactly one highlighted current day"
)
expect(
    CalendarDisplayText.year(year2026.year) == "2026年",
    "Calendar years should render as ungrouped digits"
)

print("RequirementCoreChecks passed")

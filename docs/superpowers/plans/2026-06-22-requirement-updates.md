# Requirement Updates Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Add richer time display, overview date filtering, card removal animation, MR-gated merge transitions, differentiated status icons, MR prompt on tested transition, and a placeholder settings window.

**Architecture:** Keep business rules in `RequirementCore` where they can be checked by `RequirementCoreChecks`, keep app state transitions in `RequirementStore`, and keep SwiftUI changes close to the existing row, overview, and app delegate files. Reuse the current native menu and window-controller patterns instead of introducing a new app architecture.

**Tech Stack:** Swift 6, SwiftPM, macOS SwiftUI/AppKit, SF Symbols, existing `RequirementCoreChecks` executable.

---

### Task 1: Core Filters And Time Formatting

**Files:**
- Modify: `Sources/RequirementCore/RequirementQuery.swift`
- Modify: `Checks/RequirementCoreChecks/main.swift`

- [x] **Step 1: Write failing checks**

Add checks proving custom date ranges and complete-time formatting:

```swift
let preciseDate = makeDate(year: 2026, month: 6, day: 19, hour: 15, minute: 42)
expect(
    RequirementDateDisplayFormatter.displayText(for: preciseDate, calendar: calendar) == "2026年6月19日 15:42",
    "Display formatter should include time when hour/minute are present"
)
expect(
    RequirementDateDisplayFormatter.displayText(for: referenceDate, calendar: calendar) == "2026年6月19日",
    "Display formatter should show day only for midnight dates"
)

let range = RequirementDateRange(start: referenceDate, end: referenceDate.addingTimeInterval(86_400))
let inRange = requirement("ZSTAC-9", stage: .pending, createdAt: referenceDate.addingTimeInterval(60))
let outOfRange = requirement("ZSTAC-10", stage: .pending, createdAt: referenceDate.addingTimeInterval(172_800))
expect(
    RequirementQuery.sorted([inRange, outOfRange], dateRange: range, calendar: calendar).map(\.jiraKey) == ["ZSTAC-9"],
    "Custom range filtering should keep only requirements whose activity date is inside the range"
)
```

- [x] **Step 2: Run red check**

Run: `swift run RequirementCoreChecks`

Expected: compile failure because `RequirementDateDisplayFormatter`, `RequirementDateRange`, and `dateRange` overload do not exist.

- [x] **Step 3: Implement core helpers**

Add `RequirementDateRange`, `RequirementDateDisplayFormatter`, and date-range-aware `RequirementQuery.sorted/stats`.

- [x] **Step 4: Run green check**

Run: `swift run RequirementCoreChecks`

Expected: `RequirementCoreChecks passed`.

### Task 2: Store State Rules

**Files:**
- Modify: `Sources/RequirementCore/Requirement.swift`
- Modify: `Checks/RequirementCoreChecks/main.swift`
- Modify: `Sources/RequirementTracker/RequirementStore.swift`

- [x] **Step 1: Write failing checks**

Add checks for MR-gated merge transitions:

```swift
var mergeCandidate = requirement("ZSTAC-11", stage: .completed, isDone: true, isTested: true, createdAt: referenceDate)
expect(!mergeCandidate.hasMergeRequestURL, "Blank MR should not satisfy merge requirement")
mergeCandidate.mrURL = " http://gitlab.zstack.io/demo/-/merge_requests/1 "
expect(mergeCandidate.hasMergeRequestURL, "Non-blank MR should satisfy merge requirement")
```

- [x] **Step 2: Run red check**

Run: `swift run RequirementCoreChecks`

Expected: compile failure because `hasMergeRequestURL` does not exist.

- [x] **Step 3: Implement rule**

Add `Requirement.hasMergeRequestURL`, update `RequirementStore.advance(id:)` to refuse tested-to-merged when MR is blank and set `lastNotice = "请先填写 MR 地址"`.

- [x] **Step 4: Run green check**

Run: `swift run RequirementCoreChecks`

Expected: `RequirementCoreChecks passed`.

### Task 3: Row Interaction Updates

**Files:**
- Modify: `Sources/RequirementTracker/RequirementRowView.swift`

- [x] Add `onRequestMR` flow so the action from "开发完成" to "已测试" opens the existing MR editor first.
- [x] Allow saving that MR editor with a blank value, then call the store transition into tested state.
- [x] Keep tested-to-merged calling `store.advance(id:)`, so the MR gate from Task 2 applies.
- [x] Use distinct action icons: start `play.fill`, finish `flag.checkered`, test `checkmark.seal`, merge `arrow.triangle.merge`, continue `arrow.clockwise`.
- [x] Add row removal transition using bottom-to-top move plus scale/opacity.

### Task 4: Overview Date Range And Merge Validation

**Files:**
- Modify: `Sources/RequirementTracker/RequirementOverviewView.swift`

- [x] Add overview `@State` date filter.
- [x] Apply it to stats, sidebar list, search, and selection.
- [x] Add compact date range controls near the search bar.
- [x] Disable saving a draft that changes status to merged while MR is blank.
- [x] Show a small inline validation message beside the MR field.
- [x] Use the shared date formatter for list summaries, read-only header, and timeline rows.

### Task 5: Settings Window

**Files:**
- Modify: `Sources/RequirementTracker/RequirementPanelView.swift`
- Modify: `Sources/RequirementTracker/RequirementTrackerApp.swift`
- Create: `Sources/RequirementTracker/RequirementSettingsView.swift`

- [x] Add `onOpenSettings` callback to the panel.
- [x] Add "设置" menu item above "关于".
- [x] Implement a placeholder settings window with the same independent controller pattern as Overview/About.
- [x] Keep placeholder content explicit: no configurable behavior yet.

### Task 6: Verification

**Files:**
- All modified files

- [x] Run `swift run RequirementCoreChecks`.
- [x] Run `swift build`.
- [x] Run `git diff --check`.
- [x] Review `git diff --stat` and requirement checklist before reporting.

# Requirement Tools Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build configurable Ghostty script launchers and quick-link menus in the requirement tracker.

**Architecture:** Put durable data models and JXA generation in `RequirementCore`, keep persistence and platform execution in `RequirementTracker`, and inject a shared settings store from the app delegate. Extend the existing native menu wrapper with submenu support instead of replacing the popover menu system.

**Tech Stack:** SwiftPM, SwiftUI, AppKit, JSON persistence, Ghostty AppleScript/JXA through `/usr/bin/osascript`.

---

### Task 1: Core Models And JXA Builder

**Files:**
- Modify: `Checks/RequirementCoreChecks/main.swift`
- Create: `Sources/RequirementCore/RequirementToolConfiguration.swift`
- Create: `Sources/RequirementCore/GhosttyAutomationScript.swift`

- [ ] Add failing checks for valid script projects, quick links, and generated JXA containing `newWindow`, `newTab`, `initialWorkingDirectory`, and escaped script input.
- [ ] Run `swift run RequirementCoreChecks` and confirm it fails because the new types do not exist.
- [ ] Implement the codable configuration models and JXA builder.
- [ ] Run `swift run RequirementCoreChecks` and confirm it passes.

### Task 2: Settings Persistence And Ghostty Service

**Files:**
- Create: `Sources/RequirementTracker/RequirementSettingsStore.swift`
- Create: `Sources/RequirementTracker/GhosttyScriptLauncher.swift`
- Modify: `Sources/RequirementTracker/RequirementTrackerApp.swift`

- [ ] Add an observable settings store backed by `Application Support/RequirementTracker/settings.json`.
- [ ] Add project and bookmark mutation methods that trim invalid data before saving.
- [ ] Add a launcher service that runs `/usr/bin/osascript -l JavaScript -e <generated script>` and stores returned Ghostty window ids per project during the app session.
- [ ] Inject the settings store into the popover and settings window.

### Task 3: Settings Window UI

**Files:**
- Replace: `Sources/RequirementTracker/RequirementSettingsView.swift`

- [ ] Build a top tab selector with Base, Plugin, Scripts, and Quick Access sections.
- [ ] Keep Base and Plugin as empty placeholders.
- [ ] Build the script configuration split view: project list on the left, folder picker add button, and script name/body editors on the right.
- [ ] Build quick access configuration with repeatable name and URL editors plus add/delete controls.

### Task 4: Popover Header And Menus

**Files:**
- Modify: `Sources/RequirementTracker/NativeIconMenuButton.swift`
- Modify: `Sources/RequirementTracker/RequirementPanelView.swift`

- [ ] Extend native menu content with submenus.
- [ ] Add icon-only script and quick-link buttons in the popover header.
- [ ] Hide script and quick-link buttons when there is no valid configured data.
- [ ] Make Add icon-only and hide all header utility buttons while adding.
- [ ] Wire script menu items to the Ghostty launcher and quick links to `NSWorkspace.shared.open`.

### Task 5: Verify, Commit, Relaunch

**Files:**
- All changed files.

- [ ] Run `swift run RequirementCoreChecks`.
- [ ] Run `swift build`.
- [ ] Copy `.build/debug/RequirementTracker` into `dist/需求记录.app/Contents/MacOS/RequirementTracker`.
- [ ] Code sign the app bundle.
- [ ] Relaunch the development app.
- [ ] Commit the feature.

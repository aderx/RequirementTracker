# Requirement Tools Design

## Goal

Add configurable script launchers and quick links to the requirement popover, with a native-feeling settings window for future feature configuration.

## Scope

- The popover header uses icon-only controls.
- The Add flow hides header utility buttons while the add editor is open.
- Script launcher and quick-link buttons are hidden when no valid configured data exists.
- Settings has four top tabs: base settings, plugin settings, script configuration, and quick access configuration.
- Script projects are local folders. Each project can contain multiple scripts, each with a name and multiline script body.
- Quick links are name and URL pairs.
- Ghostty launches are driven by its macOS AppleScript dictionary. A project should map to one Ghostty window, and each run opens a new tab in that project window when possible.

## Architecture

- `RequirementCore` owns codable configuration models and the pure Ghostty automation script builder so behavior can be checked without UI.
- `RequirementTracker` owns settings persistence, SwiftUI settings views, native menus, and process execution for `/usr/bin/osascript`.
- The app delegate creates one settings store and injects it into both the popover and settings window.

## Verification

- Add checks to `RequirementCoreChecks` for valid configuration filtering and Ghostty automation script generation.
- Run `swift run RequirementCoreChecks`.
- Run `swift build`.
- Relaunch the development app bundle after copying the debug executable into `dist/需求记录.app`.

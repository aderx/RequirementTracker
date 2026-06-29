# RequirementTracker Agent Workflow

This file is the single project-level workflow source for Codex, Claude Code, and other coding agents. Agent-specific entry files must point here instead of duplicating these rules.

## Core Principles

- Respond in concise Chinese unless the user explicitly asks for English.
- Treat this repository as a shipped local macOS app plus a browser extension. A source build is not enough; the installed app in `/Applications` must be updated when releasing.
- Prefer source and runtime evidence over assumptions. Report whether a conclusion is verified, inferred, or unknown when it matters.
- Do not delete user data. Runtime data lives outside the repo under `~/Library/Application Support/RequirementTracker`.

## Branch And Version Flow

- Before any code/config change, inspect the current branch, working tree, and version state.
- All development starts from the latest `main`.
- If the current branch is `main`, or the previous feature/fix branch has already been merged, create a new branch before editing.
- Branch names use grouped semantic version paths: `<major>.x/<major>.<minor>.<patch>`.
- Examples: `1.x/1.8.0`, `1.x/1.8.1`, `2.x/2.0.0`.
- Only App/plugin code changes or behavior changes that ship in the production app require a version bump.
- Documentation-only, agent-configuration-only, workflow-rule-only, or comment-only changes do not require changing the App/plugin version unless the user explicitly asks for a versioned release.
- Version meaning:
  - `major`: breaking or incompatible behavior changes.
  - `minor`: new features or workflow capability changes.
  - `patch`: bug fixes, packaging fixes, and narrow regressions.
- Bug fixes still use a fresh version branch. Use grouped names such as `1.x/1.8.1` to keep the branch list manageable.
- Do not delete merged version branches by default. Historical branches are retained for traceability.
- After opening a new version branch for an App/plugin release, update all user-visible version metadata in the same change:
  - App about/version fallback in source.
  - App bundle `CFBundleShortVersionString` and `CFBundleVersion` when packaging.
  - Chrome extension `manifest.json` version.
- The current baseline after this workflow update is `1.8.0`. Future App/plugin changes should start from `1.8.0` and increment according to the semantic version rules above.

## Development Loop

- Implement the smallest effective change for the requested behavior.
- Do not broaden the scope without explaining why the broader change is required.
- After code changes, start the development build for user verification.
- For this SwiftPM macOS app, the development launch path is:
  - Stop existing development instances of `RequirementTracker`.
  - Run `swift run RequirementTracker`.
- The user validates UI behavior manually. Do not mark the feature complete before the user confirms.

## Delivery Flow

- After the user confirms validation, commit the version branch.
- Push the version branch to GitHub.
- Create a GitHub PR from the version branch into `main`.
- Auto-merge the PR into `main` when checks and repository settings allow it.
- If auto-merge is unavailable, report the exact blocker and wait for user direction.
- After merge, switch to `main` and pull the latest remote `main`.

## Production Build And Install Flow

- Build the release binary from `main` only.
- Use `swift build -c release` for release binaries.
- Rebuild the production app bundle before installing:
  - Copy `.build/release/RequirementTracker` into `dist/需求记录.app/Contents/MacOS/RequirementTracker`.
  - Copy `.build/release/JiraRequirementNativeHost` into `dist/需求记录.app/Contents/Resources/JiraRequirementNativeHost`.
  - Copy `Integrations/JiraRequirementCapture/extension` into `dist/需求记录.app/Contents/Resources/JiraRequirementCaptureExtension`.
  - Update `dist/需求记录.app/Contents/Info.plist` to the branch version.
  - Re-sign the bundle.
- Never treat updating only `dist/需求记录.app` as a completed local install.
- Replace the installed app at `/Applications/需求记录.app` with the rebuilt bundle.
- After replacement, verify:
  - `/Applications/需求记录.app/Contents/Info.plist` has the expected `CFBundleShortVersionString`.
  - `/Applications/需求记录.app/Contents/Resources/JiraRequirementCaptureExtension/manifest.json` has the expected extension version.
  - The Chrome Native Messaging manifest points to `/Applications/需求记录.app/Contents/Resources/JiraRequirementNativeHost`.
  - The running `RequirementTracker` process path is `/Applications/需求记录.app/Contents/MacOS/RequirementTracker`.

## Process Management

- Before installing a production build, terminate all running development and production instances of `RequirementTracker`.
- Be specific when killing processes. Prefer exact process names or verified PIDs.
- After installation, start the new production app from `/Applications/需求记录.app`.
- Do not leave a raw `.build/.../debug/RequirementTracker` process running after handing off a production build.

## Browser Extension Flow

- The installed app must include the unpacked extension at `Contents/Resources/JiraRequirementCaptureExtension`.
- The settings page "open plugin directory" action must work when the app is launched from `/Applications`.
- The Chrome Native Messaging host must not depend on a repo-local `.build` path in production.
- After replacing extension files, tell the user to reload the extension in `chrome://extensions`.

## Completion Checklist

- Current branch and version are known.
- Development happened on a version branch from `main`.
- Version metadata was updated for the same version.
- Development build was launched for user validation after code changes.
- User confirmed validation before merge/release.
- Version branch was pushed and merged into `main`.
- Release build was created from `main`.
- `/Applications/需求记录.app` was replaced, not just `dist/需求记录.app`.
- Old development and production processes were terminated.
- New production app was launched from `/Applications`.
- Merged version branches were retained unless the user explicitly asks to delete them.

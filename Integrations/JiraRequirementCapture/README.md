# Jira Requirement Capture

Chrome/Edge unpacked extension and Native Messaging host for capturing the current Jira issue page or GitLab merge request into the RequirementTracker JSON data file.

## Current Fields

- `issueKey`
- `title`
- `type`
- `priority`
- `targetVersion`
- `url`
- `capturedAt`

## Local Install

1. Open `chrome://extensions`.
2. Enable `Developer mode`.
3. Click `Load unpacked`.
4. Select this directory: `Integrations/JiraRequirementCapture/extension`.
5. Copy the generated extension id from `chrome://extensions`.
6. From the repository root, run:

   ```sh
   ./Scripts/install-jira-native-host.sh <extension-id>
   ```

7. Pin the extension to the browser toolbar.
8. Open a Jira issue page or GitLab MR page and click the extension icon once.

## Notes

- The popup uses `activeTab` and only reads page content after you click the extension. A background service worker uses the `tabs` permission to read the current tab's URL (not its content) so it can show an icon badge.
- The icon shows a bottom-right status badge per tab: green `✓` when the page URL is already recorded, blue `+` when it is a supported Jira/MR page that is not recorded yet, and a gray `–` when the page is unsupported.
- When adding or updating a Jira, the popup also offers a `确认并开始开发` button. It saves the issue and, if the requirement is not started yet (or does not exist), creates it / moves it to `开发中`. Requirements already in progress or completed keep their status. The countdown default stays on the original confirm/close button.
- Jira issue pages are detected by `/browse/<KEY>`. Non-detail Jira pages and unsupported pages show a short popup and close automatically.
- GitLab MR pages are detected from the MR host list in the app's plugin settings. The extension reads Jira links from actual page anchors, not link text.
- Existing Jira issues and existing MR links are confirmed in the popup. Defaults run after 3 seconds.
- Jira and MR URLs are saved without query strings or hash fragments.
- It first tries common Jira DOM ids such as `#summary-val`, `#type-val`, `#priority-val`, and `#fixVersions-field`.
- If those ids are missing, it falls back to nearby field labels such as `类型`, `优先级`, and `修复的版本`.
- Popup actions send payloads to `JiraRequirementNativeHost` through Chrome Native Messaging. No localhost port is used.
- The native host writes to the same default data file as the app: `~/Library/Application Support/RequirementTracker/requirements.json`.
- Before each write, the native host copies the existing data file into `~/Library/Application Support/RequirementTracker/Backups/`, then writes the new JSON atomically.
- After each write, the native host also writes an `after-jira-import` snapshot backup. This preserves the imported state if the current app later overwrites the JSON before app-side refresh/merge support is added.

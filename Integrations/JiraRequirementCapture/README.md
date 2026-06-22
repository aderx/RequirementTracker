# Jira Requirement Capture

Chrome/Edge unpacked extension and Native Messaging host for extracting fixed fields from the current Jira issue page and writing them into the RequirementTracker JSON data file.

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

7. Open a Jira issue page and click the extension icon.

## Notes

- The extension uses `activeTab`, so it only reads the current page after you click the extension.
- It first tries common Jira DOM ids such as `#summary-val`, `#type-val`, `#priority-val`, and `#fixVersions-field`.
- If those ids are missing, it falls back to nearby field labels such as `类型`, `优先级`, and `修复的版本`.
- `写入 JSON` sends the payload to `JiraRequirementNativeHost` through Chrome Native Messaging. No localhost port is used.
- The native host writes to the same default data file as the app: `~/Library/Application Support/RequirementTracker/requirements.json`.
- Before each write, the native host copies the existing data file into `~/Library/Application Support/RequirementTracker/Backups/`, then writes the new JSON atomically.
- After each write, the native host also writes an `after-jira-import` snapshot backup. This preserves the imported state if the current app later overwrites the JSON before app-side refresh/merge support is added.

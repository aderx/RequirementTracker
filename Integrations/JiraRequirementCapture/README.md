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

## Status test page

- Right-click the extension icon and choose **打开状态测试页**.
- Or open RequirementTracker settings, select **插件配置**, and click **打开测试页**.
- Each button drives the same background state resolver used by real Jira/MR pages and updates the extension icon in the browser toolbar. The page does not render a separate icon preview.
- Opening the extension popup from the test page shows matching mock requirement details. Test-mode data stays inside the extension and never reads or writes RequirementTracker App data.
- The selected state stays in the page URL, so refreshing the test page restores the same toolbar state.
- The binding panel reads the actual extension ID, version, Native Host protocol, Jira base URL, and MR hosts.

## Notes

- The popup uses `activeTab` to read requirement details after you click the extension. A small content script reads only the current Jira assignee or GitLab MR author plus the signed-in identity so the background service worker can decide whether to show the orange `+` badge.
- For an unrecorded Jira issue or GitLab MR, the orange `+` badge is hidden only when the page clearly belongs to another user. Unknown or unsupported page identity keeps the existing addable behavior, and opening the popup still allows an explicit add.
- A saved MR starts at `MR 已创建`. The card's top-level menu can move it to `MR 已提交合并`, then optionally enable merge monitoring. While Chrome is running, the extension checks monitored MRs every 15 minutes using the existing GitLab login. A merged result updates only the MR sub-status and reminder fields through Native Host; it never advances the requirement's main status or its normal sorting timestamp.
- The icon shows a bottom-right status badge per tab: orange `+` for an unrecorded supported page, green `↻` for a recorded requirement, green `✓` for a merged requirement, amber `Ⅱ` for a paused requirement, and red `■` for a stopped requirement. Unsupported pages have no badge. The popup shows the pause/stop reason in a separate highlighted row below the summary card.
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

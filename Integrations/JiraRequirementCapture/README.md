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

## Automatic MR status (1.19.0)

- Opening an MR already bound to a recorded requirement advances it to `已自测`. A merged MR advances it to `已合并`.
- For the first MR binding, the page must clearly belong to the signed-in user and identify exactly one existing requirement in its title/description. Existing MR bindings take precedence. New requirements are never created automatically.
- Paused/stopped requirements and historical MRs are excluded; repeat visits do not append duplicate history or change timestamps. A different MR must be bound manually before it can advance an existing MR association.
- GitLab page updates trigger synchronization without opening the popup. While Chrome runs, the existing 15-minute alarm also checks the latest MR of recorded, active requirements. Background automatic merge checks require a structured GitLab response; login redirects, network errors and unknown responses leave data unchanged.
- Both the extension and Native Host must be updated. During development, load the extension from the development app's `Contents/Resources/JiraRequirementCaptureExtension`, then set its extension ID and install Native Host from that development app's plugin settings. Reload existing MR tabs after updating the extension.

## Status test page

- Right-click the extension icon and choose **打开状态测试页**.
- Or open RequirementTracker settings, select **插件配置**, and click **打开测试页**.
- Each button drives the same background state resolver used by real Jira/MR pages and updates the extension icon in the browser toolbar. The page does not render a separate icon preview.
- Opening the extension popup from the test page shows matching mock requirement details. Test-mode data stays inside the extension and never reads or writes RequirementTracker App data.
- The selected state stays in the page URL, so refreshing the test page restores the same toolbar state.
- The binding panel reads the actual extension ID, version, Native Host protocol, Jira base URL, and MR hosts.

## Notes

- The popup uses `activeTab` to read requirement details after you click the extension. The content script reads page identity for badge eligibility and extracts the MR state plus scoped title/description references for automatic synchronization.
- For an unrecorded Jira issue or GitLab MR, the orange `+` badge is hidden only when the page clearly belongs to another user. Unknown or unsupported page identity keeps the existing addable behavior, and opening the popup still allows an explicit add.
- A saved MR starts at `MR 已创建`. The card's top-level menu can move it to `MR 已提交合并`, then optionally enable merge monitoring. While Chrome is running, the extension checks monitored MRs every 15 minutes using the existing GitLab login. In 1.19.0 the automatic path advances eligible requirements to merged; the legacy explicit reminder path remains available for records excluded from automatic status progression.
- The icon shows a bottom-right status badge per tab: orange `+` for an unrecorded supported page, green `↻` for a recorded requirement, green `✓` for a merged requirement, amber `Ⅱ` for a paused requirement, and red `■` for a stopped requirement. Unsupported pages have no badge. The popup shows the pause/stop reason in a separate highlighted row below the summary card.
- When adding or updating a Jira, the popup also offers a `确认并开始开发` button. It saves the issue and, if the requirement is not started yet (or does not exist), creates it / moves it to `开发中`. Requirements already in progress or completed keep their status. The countdown default stays on the original confirm/close button.

### Status actions and issue lists (2.1)

- Recorded Jira issues and already associated MR pages offer `暂停`, `停止`, and `一键完成` in the popup's top-right `状态` menu. Every action requires a new explanation in the popup. These actions update only RequirementTracker, not Jira or GitLab.
- Manual corrections can switch any recorded status to any of these three statuses. The current status is disabled, and the Native Host rejects repeated, ambiguous, or stale status operations inside the write transaction. Moving a completed requirement to paused/stopped keeps its MR links and status history; it does not undo a GitLab merge. Failed submissions retain the entered reason.
- Jira `/issues/` lists, including “我未完成的问题”, append the toolbar's status icon inside each issue-key link after its existing contents. The original link node, text, attributes, and click handlers remain intact; the icon has no text and does not intercept pointer events. Hovering or focusing the link displays the icon and full status name in a separate tooltip, so expansion does not affect table layout. Unrecorded issues, duplicate local records, and connection errors are distinct states.
- The list popup's `显示悬浮状态` switch defaults to on. Turning it off affects only the current tab's current document, including reopening the popup; reloading/navigating to a new document restores the default. Hidden overlays do not poll for status, and no preference is saved to browser storage.
- List reads are batched (up to 100 keys), refresh after pagination/filter changes and popup writes, and refresh every 30 seconds while visible or when returning to the tab. Reading a list does not import issues or update requirement history.
- For a list that was already open when the extension was installed/reloaded, opening the popup injects the list icons and styles directly without reloading Jira.
- New operations are advertised by Native Host capabilities; older hosts show disabled status-menu entries with an explicit update prompt, and list lookups also explain the mismatch. Reload the extension and Jira tabs after updating both the extension and its Native Host.
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

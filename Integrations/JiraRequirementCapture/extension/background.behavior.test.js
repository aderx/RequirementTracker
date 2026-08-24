const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const backgroundSource = fs.readFileSync(path.join(__dirname, "background.js"), "utf8");

function eventStub() {
  return { addListener() {} };
}

function createBackground(nativeStub) {
  const actionCalls = {
    badgeTexts: [],
    badgeBackgrounds: [],
    badgeTextColors: [],
    icons: [],
    titles: []
  };
  const alarmCalls = [];
  const badgeStyles = {
    addable: { label: "可添加", text: "+", color: "#FF9500" },
    recorded: { label: "已记录", text: "↻", color: "#1F9D54" },
    done: { label: "开发完成", text: "✓", color: "#1570EF" },
    tested: { label: "已自测", text: "\u2714\uFE0E", color: "#7F56D9" },
    merged: { label: "已合并", text: "⇧", color: "#1F9D54" },
    paused: { label: "已暂停", text: "Ⅱ", color: "#F59E0B" },
    stopped: { label: "已停止", text: "■", color: "#D92D43" }
  };
  const sandbox = {
    URL,
    console,
    importScripts() {},
    BadgeIconRenderer: {
      styles: badgeStyles
    },
    chrome: {
      runtime: {
        lastError: null,
        onInstalled: eventStub(),
        onStartup: eventStub(),
        onMessage: eventStub(),
        getURL(value) {
          return `chrome-extension://abcdefghijklmnopabcdefghijklmnop/${value}`;
        },
        sendNativeMessage() {}
      },
      tabs: {
        onActivated: eventStub(),
        onUpdated: eventStub(),
        get() {},
        query() {},
        create() {},
        async sendMessage() {
          return { ownership: "unknown" };
        }
      },
      alarms: {
        onAlarm: eventStub(),
        create(name, options) {
          alarmCalls.push({ name, options });
        }
      },
      contextMenus: {
        onClicked: eventStub(),
        remove(_id, callback) {
          callback();
        },
        create(_details, callback) {
          callback();
        }
      },
      action: {
        setIcon(details) {
          actionCalls.icons.push(details);
        },
        setBadgeText(details) {
          actionCalls.badgeTexts.push(details);
        },
        setBadgeBackgroundColor(details) {
          actionCalls.badgeBackgrounds.push(details);
        },
        setBadgeTextColor(details) {
          actionCalls.badgeTextColors.push(details);
        },
        setTitle(details) {
          actionCalls.titles.push(details);
        }
      }
    }
  };

  const exposure = [
    "globalThis.__background = {",
    "  BADGE_STYLES,",
    "  applyBadge,",
    "  handleRuntimeMessage,",
    "  checkMonitoredMRs,",
    "  extractMRStateFromResponseText,",
    "  resolveState,",
    "  testStateFromURL,",
    "  setNativeMessageStub(stub) { sendNativeMessage = stub; },",
    "  setPageOwnershipStub(stub) { readPageOwnership = stub; },",
    "  setFetchMRStateStub(stub) { fetchMRState = stub; }",
    "};"
  ].join("\n");
  vm.createContext(sandbox);
  vm.runInContext(backgroundSource + "\n" + exposure, sandbox);
  sandbox.__background.setNativeMessageStub(nativeStub);
  sandbox.__background.actionCalls = actionCalls;
  sandbox.__background.alarmCalls = alarmCalls;
  return sandbox.__background;
}

function nativeStubFor({ exists, status, protocolVersion = 3 }) {
  return async (message) => {
    if (message.type === "getPluginSettings") {
      return {
        ok: true,
        protocolVersion,
        settings: {
          jiraBaseURL: "http://jira.zstack.io/browse/",
          mrHosts: ["gitlab.zstack.io"]
        }
      };
    }

    return { ok: true, exists, status };
  };
}

async function testBadgeStylesDifferentiateMilestones() {
  const background = createBackground(nativeStubFor({ exists: true, status: "merged" }));
  const styles = background.BADGE_STYLES;
  assert.equal(styles.recorded.label, "已记录");
  assert.equal(styles.recorded.text, "↻");
  assert.equal(styles.recorded.color, "#1F9D54");
  assert.equal(styles.done.label, "开发完成");
  assert.equal(styles.tested.label, "已自测");
  assert.equal(styles.tested.text, "\u2714\uFE0E");
  assert.equal(styles.merged.label, "已合并");
  assert.equal(styles.paused.text, "Ⅱ");
  assert.equal(styles.stopped.text, "■");
  assert.notEqual(styles.done.color, styles.tested.color);
  assert.notEqual(styles.tested.color, styles.merged.color);
}

async function testEveryStatusUsesTheChromeNativeOverflowBadge() {
  const background = createBackground(nativeStubFor({ exists: true, status: "merged" }));

  for (const [state, style] of Object.entries(background.BADGE_STYLES)) {
    await background.applyBadge(42, state);
    assert.equal(background.actionCalls.badgeTexts.at(-1)?.text, style.text);
    assert.equal(background.actionCalls.icons.at(-1)?.path?.[16], "icons/icon-16.png");
    assert.equal(background.actionCalls.badgeBackgrounds.at(-1)?.color, style.color);
    assert.equal(background.actionCalls.badgeTextColors.at(-1)?.color, "#FFFFFF");
    assert.equal(background.actionCalls.titles.at(-1)?.title, `需求记录：${style.label}`);
  }

  await background.applyBadge(42, "unsupported");
  assert.equal(background.actionCalls.badgeTexts.at(-1)?.text, "");
  assert.equal(background.actionCalls.icons.at(-1)?.path?.[16], "icons/icon-16.png");
  assert.equal(background.actionCalls.titles.at(-1)?.title, "记录 Jira / MR");
}

async function testMilestoneJiraUsesDedicatedBadge() {
  for (const status of ["done", "tested", "merged"]) {
    const background = createBackground(nativeStubFor({ exists: true, status }));
    assert.equal(
      await background.resolveState("http://jira.zstack.io/browse/ZSTAC-12345"),
      status
    );
  }
}

async function testPendingAndActiveJiraUseRecordedBadge() {
  for (const status of ["pending", "active"]) {
    const background = createBackground(nativeStubFor({ exists: true, status }));
    assert.equal(
      await background.resolveState("http://jira.zstack.io/browse/ZSTAC-12345"),
      "recorded"
    );
  }
}

async function testPausedAndStoppedJiraUseDedicatedBadges() {
  for (const status of ["paused", "stopped"]) {
    const background = createBackground(nativeStubFor({ exists: true, status }));
    assert.equal(
      await background.resolveState("http://jira.zstack.io/browse/ZSTAC-12345"),
      status
    );
  }

  const background = createBackground(nativeStubFor({ exists: true, status: "paused" }));
  await background.applyBadge(42, "paused");
  assert.equal(background.actionCalls.badgeTexts.at(-1)?.text, "Ⅱ");
  assert.equal(background.actionCalls.badgeBackgrounds.at(-1)?.color, "#F59E0B");

  await background.applyBadge(42, "stopped");
  assert.equal(background.actionCalls.badgeTexts.at(-1)?.text, "■");
  assert.equal(background.actionCalls.badgeBackgrounds.at(-1)?.color, "#D92D43");
}

async function testMergedRequirementMRPageUsesMergedBadge() {
  const background = createBackground(nativeStubFor({ exists: true, status: "merged" }));
  assert.equal(
    await background.resolveState("http://gitlab.zstack.io/g/p/-/merge_requests/1"),
    "merged"
  );
}

async function testUnrecordedPageUsesAddableBadge() {
  const background = createBackground(nativeStubFor({ exists: false }));
  assert.equal(
    await background.resolveState("http://jira.zstack.io/browse/ZSTAC-12345"),
    "addable"
  );
}

async function testOtherOwnersDoNotShowTheAddBadge() {
  const background = createBackground(nativeStubFor({ exists: false }));
  background.setPageOwnershipStub(async () => "other");
  assert.equal(
    await background.resolveState("http://jira.zstack.io/browse/ZSTAC-12345", 42),
    "unsupported"
  );

  background.setPageOwnershipStub(async () => "mine");
  assert.equal(
    await background.resolveState("http://gitlab.zstack.io/g/p/-/merge_requests/1", 42),
    "addable"
  );
}

async function testMRMonitorMarksMergedWithoutChangingMainStatusItself() {
  const messages = [];
  const background = createBackground(async (message) => {
    messages.push(message);
    if (message.type === "listMRMergeMonitors") {
      return {
        ok: true,
        monitors: [{
          issueKey: "ZSTAC-12345",
          mrURL: "http://gitlab.zstack.io/g/p/-/merge_requests/1"
        }]
      };
    }
    return { ok: true };
  });
  background.setFetchMRStateStub(async () => "merged");

  await background.checkMonitoredMRs();

  assert.equal(messages.length, 2);
  assert.equal(messages[1].type, "markMRMergeMonitorMerged");
  assert.equal(messages[1].payload.issueKey, "ZSTAC-12345");
  assert.equal(
    messages[1].payload.mrURL,
    "http://gitlab.zstack.io/g/p/-/merge_requests/1"
  );
}

async function testMRStateExtractionUsesStructuredGitLabFieldsOnly() {
  const background = createBackground(nativeStubFor({ exists: false }));
  assert.equal(
    background.extractMRStateFromResponseText('{"state":"merged"}'),
    "merged"
  );
  assert.equal(
    background.extractMRStateFromResponseText(
      '<div data-page="{&quot;state&quot;:&quot;open&quot;}"></div>'
    ),
    "open"
  );
  assert.equal(
    background.extractMRStateFromResponseText("A comment says this was merged yesterday"),
    ""
  );
}

async function testIncompatibleNativeHostClearsBadge() {
  const background = createBackground(nativeStubFor({
    exists: true,
    status: "merged",
    protocolVersion: 1
  }));
  assert.equal(
    await background.resolveState("http://jira.zstack.io/browse/ZSTAC-12345"),
    "unsupported"
  );
}

async function testStatusTestPageRestoresStateFromURL() {
  const background = createBackground(() => {
    throw new Error("Test page state should not call Native Host");
  });
  const testURL = "chrome-extension://abcdefghijklmnopabcdefghijklmnop/test.html?state=tested";
  assert.equal(background.testStateFromURL(testURL), "tested");
  assert.equal(await background.resolveState(testURL), "tested");
  assert.equal(
    background.testStateFromURL(
      "chrome-extension://abcdefghijklmnopabcdefghijklmnop/test.html?state=unknown"
    ),
    "unsupported"
  );
}

async function testStatusTestPageDrivesTheRealToolbarStatePath() {
  const background = createBackground(() => {
    throw new Error("Test page state should not call Native Host");
  });
  const testURL = "chrome-extension://abcdefghijklmnopabcdefghijklmnop/test.html?state=tested";
  let keepMessagePortOpen = false;
  const responsePromise = new Promise((resolve) => {
    keepMessagePortOpen = background.handleRuntimeMessage(
      {
        type: "APPLY_TEST_PAGE_STATE",
        url: testURL
      },
      { tab: { id: 42 } },
      resolve
    );
  });

  assert.equal(keepMessagePortOpen, true);
  const response = await responsePromise;
  assert.equal(response.ok, true);
  assert.equal(response.state, "tested");
  assert.equal(background.actionCalls.badgeTexts.at(-1)?.tabId, 42);
  assert.equal(background.actionCalls.badgeTexts.at(-1)?.text, "\u2714\uFE0E");
  assert.equal(background.actionCalls.icons.at(-1)?.path?.[16], "icons/icon-16.png");
  assert.equal(background.actionCalls.badgeBackgrounds.at(-1)?.color, "#7F56D9");
  assert.equal(background.actionCalls.titles.at(-1)?.title, "需求记录：已自测");
}

async function run() {
  await testBadgeStylesDifferentiateMilestones();
  await testEveryStatusUsesTheChromeNativeOverflowBadge();
  await testMilestoneJiraUsesDedicatedBadge();
  await testPendingAndActiveJiraUseRecordedBadge();
  await testPausedAndStoppedJiraUseDedicatedBadges();
  await testMergedRequirementMRPageUsesMergedBadge();
  await testUnrecordedPageUsesAddableBadge();
  await testOtherOwnersDoNotShowTheAddBadge();
  await testMRMonitorMarksMergedWithoutChangingMainStatusItself();
  await testMRStateExtractionUsesStructuredGitLabFieldsOnly();
  await testIncompatibleNativeHostClearsBadge();
  await testStatusTestPageRestoresStateFromURL();
  await testStatusTestPageDrivesTheRealToolbarStatePath();
}

run().then(() => {
  console.log("background.behavior.test.js passed");
}).catch((error) => {
  console.error(error);
  process.exitCode = 1;
});

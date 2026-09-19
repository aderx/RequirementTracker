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
  const sandbox = {
    URL,
    console,
    importScripts() {},
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
    "  synchronizeMRForTab,",
    "  fetchMRState,",
    "  setFetchStub(stub) { globalThis.fetch = stub; },",
    "  setTabStub(stub) { chrome.tabs.get = stub; },",
    "  setContextStub(stub) { chrome.tabs.sendMessage = stub; },",
    "  testStateFromURL,",
    "  setNativeMessageStub(stub) { sendNativeMessage = stub; },",
    "  setPageOwnershipStub(stub) { readPageOwnership = stub; },",
    "  setFetchMRStateStub(stub) { fetchMRState = stub; }",
    "};"
  ].join("\n");
  vm.createContext(sandbox);
  vm.runInContext(fs.readFileSync(path.join(__dirname, "badge-renderer.js"), "utf8"), sandbox);
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

async function testStatusIconsReplaceWholeIconAndUnsupportedRestoresLogo() {
  const background = createBackground(nativeStubFor({ exists: true, status: "merged" }));

  for (const [state, style] of Object.entries(background.BADGE_STYLES)) {
    await background.applyBadge(42, state);
    assert.equal(background.actionCalls.badgeTexts.at(-1)?.text, "");
    for (const size of [16, 32, 48, 128]) {
      const iconPath = background.actionCalls.icons.at(-1)?.path?.[size];
      assert.equal(iconPath, `icons/status/${state}-${size}.png`);
      assert.ok(fs.existsSync(path.join(__dirname, iconPath)));
    }
    assert.equal(background.actionCalls.badgeBackgrounds.length, 0);
    assert.equal(background.actionCalls.badgeTextColors.length, 0);
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
  assert.equal(background.actionCalls.badgeTexts.at(-1)?.text, "");
  assert.equal(background.actionCalls.icons.at(-1)?.path?.[16], "icons/status/paused-16.png");

  await background.applyBadge(42, "stopped");
  assert.equal(background.actionCalls.badgeTexts.at(-1)?.text, "");
  assert.equal(background.actionCalls.icons.at(-1)?.path?.[16], "icons/status/stopped-16.png");
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

  const writes = messages.filter(message => message.type !== "getPluginSettings");
  assert.equal(writes.length, 2);
  assert.equal(writes[1].type, "markMRMergeMonitorMerged");
  assert.equal(writes[1].payload.issueKey, "ZSTAC-12345");
  assert.equal(
    writes[1].payload.mrURL,
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
  assert.equal(background.actionCalls.badgeTexts.at(-1)?.text, "");
  assert.equal(background.actionCalls.icons.at(-1)?.path?.[16], "icons/status/tested-16.png");
  assert.equal(background.actionCalls.titles.at(-1)?.title, "需求记录：已自测");
}

async function testAutomaticMRTransitionsAndGuards() {
  const mrURL = "http://gitlab.zstack.io/g/p/-/merge_requests/123";
  for (const scenario of [
    { name: "bound open MR", exists: true, state: "open", expected: 1 },
    { name: "bound merged MR", exists: true, state: "merged", expected: 1 },
    { name: "initial explicit own association", exists: false, owner: "mine", keys: ["ZSTAC-123"], expected: 1 },
    { name: "unknown author", exists: false, keys: ["ZSTAC-123"], expected: 0 },
    { name: "ambiguous references", exists: false, owner: "mine", keys: ["ZSTAC-123", "ZSTAC-456"], expected: 0 },
    { name: "unrecorded requirement", exists: false, owner: "mine", keys: ["ZSTAC-123"], missing: true, expected: 0 },
    { name: "closed MR", exists: true, state: "closed", expected: 0 },
    { name: "navigation raced", exists: true, moved: true, expected: 0 },
    { name: "old Host", exists: true, old: true, expected: 0 }
  ]) {
    const writes = [];
    const background = createBackground(async message => {
      if (message.type === "getPluginSettings") return {
        ok: true, protocolVersion: 3, supportsAutomaticMRStatus: !scenario.old,
        settings: { jiraBaseURL: "http://jira.zstack.io/browse/", mrHosts: ["gitlab.zstack.io"] }
      };
      if (message.type === "inspectByURL") return { ok: true, exists: scenario.exists, issueKey: "ZSTAC-123" };
      if (message.type === "inspectRequirement") return { ok: true, exists: !scenario.missing };
      writes.push(message);
      return { ok: true };
    });
    background.setContextStub(async () => ({ ok: true, result: {
      mrURL, mrState: scenario.state || "open", ownership: scenario.owner || "unknown", issueKeys: scenario.keys || []
    } }));
    background.setTabStub(async () => ({ url: scenario.moved ? `${mrURL}4` : `${mrURL}/diffs` }));
    await Promise.all([background.synchronizeMRForTab(42, mrURL), background.synchronizeMRForTab(42, mrURL)]);
    assert.equal(writes.length, scenario.expected, scenario.name);
    if (writes.length) {
      assert.equal(writes[0].type, "syncMRStatus");
      assert.equal(writes[0].payload.mrState, scenario.state || "open");
    }
  }
}

async function testAutomaticMergeMonitoring() {
  const writes = [];
  const background = createBackground(async message => {
    if (message.type === "getPluginSettings") return { ok: true, protocolVersion: 3, supportsAutomaticMRStatus: true };
    if (message.type === "listMRMergeMonitors") return { ok: true, monitors: [] };
    if (message.type === "listAutomaticMRMonitors") return { ok: true, monitors: [
      { issueKey: "ZSTAC-123", mrURL: "http://gitlab.zstack.io/g/p/-/merge_requests/1", automatic: true },
      { issueKey: "ZSTAC-456", mrURL: "http://gitlab.zstack.io/g/p/-/merge_requests/2", automatic: true }
    ] };
    writes.push(message); return { ok: true };
  });
  background.setFetchMRStateStub(async (url, strict) => {
    assert.equal(strict, true);
    return url.endsWith("/1") ? "merged" : "open";
  });
  await background.checkMonitoredMRs();
  assert.equal(writes.length, 1);
  assert.equal(writes[0].type, "syncMRStatus");
  assert.equal(writes[0].payload.mrState, "merged");
}

async function testAutomaticMonitorRejectsUnverifiedResponses() {
  const url = "http://gitlab.zstack.io/g/p/-/merge_requests/123";
  const background = createBackground(nativeStubFor({ exists: true }));
  for (const [responseURL, body, expected] of [
    [`${url}.json`, '{"state":"merged"}', "merged"],
    [`${url}.json`, '{"merge_request":{"state":"opened"}}', "open"],
    ["http://gitlab.zstack.io/users/sign_in", '{"state":"merged"}', ""],
    [`${url}.json`, '<div data-state="merged">comment</div>', ""],
    [`${url}.json`, '{"comments":[{"state":"merged"}]}', ""]
  ]) {
    background.setFetchStub(async () => ({ ok: true, url: responseURL, text: async () => body }));
    assert.equal(await background.fetchMRState(url, true), expected);
  }
  background.setFetchStub(async () => { throw new Error("offline"); });
  assert.equal(await background.fetchMRState(url, true), "");
}

async function run() {
  await testAutomaticMonitorRejectsUnverifiedResponses();
  await testAutomaticMRTransitionsAndGuards();
  await testAutomaticMergeMonitoring();
  await testBadgeStylesDifferentiateMilestones();
  await testStatusIconsReplaceWholeIconAndUnsupportedRestoresLogo();
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

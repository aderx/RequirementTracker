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
    badgeBackgroundColors: [],
    badgeTextColors: [],
    icons: []
  };
  const sandbox = {
    URL,
    console,
    chrome: {
      runtime: {
        lastError: null,
        onInstalled: eventStub(),
        onStartup: eventStub(),
        onMessage: eventStub(),
        sendNativeMessage() {}
      },
      tabs: {
        onActivated: eventStub(),
        onUpdated: eventStub(),
        get() {},
        query() {}
      },
      action: {
        setIcon(details) {
          actionCalls.icons.push(details);
        },
        setBadgeText(details) {
          actionCalls.badgeTexts.push(details);
        },
        setBadgeBackgroundColor(details) {
          actionCalls.badgeBackgroundColors.push(details);
        },
        setBadgeTextColor(details) {
          actionCalls.badgeTextColors.push(details);
        }
      }
    }
  };

  const exposure = [
    "globalThis.__background = {",
    "  BADGE_STYLES,",
    "  applyBadge,",
    "  resolveState,",
    "  setNativeMessageStub(stub) { sendNativeMessage = stub; }",
    "};"
  ].join("\n");
  vm.createContext(sandbox);
  vm.runInContext(backgroundSource + "\n" + exposure, sandbox);
  sandbox.__background.setNativeMessageStub(nativeStub);
  sandbox.__background.actionCalls = actionCalls;
  return sandbox.__background;
}

function nativeStubFor({ exists, status, protocolVersion = 2 }) {
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
  assert.equal(styles.recorded.text, "↻");
  assert.equal(styles.recorded.color, "#1F9D54");
  assert.equal(styles.done.text, "✓");
  assert.equal(styles.tested.text, "✔");
  assert.equal(styles.merged.text, "⇧");
  assert.notEqual(styles.done.color, styles.tested.color);
  assert.notEqual(styles.tested.color, styles.merged.color);
}

async function testEveryStatusUsesNativeBadgeOnDefaultIcon() {
  const background = createBackground(nativeStubFor({ exists: true, status: "merged" }));

  for (const [state, style] of Object.entries(background.BADGE_STYLES)) {
    background.applyBadge(42, state);
    assert.equal(background.actionCalls.badgeTexts.at(-1)?.text, style.text);
    assert.equal(background.actionCalls.badgeBackgroundColors.at(-1)?.color, style.color);
    assert.equal(background.actionCalls.badgeTextColors.at(-1)?.color, "#FFFFFF");
    assert.equal(background.actionCalls.icons.at(-1)?.path?.[16], "icons/icon-16.png");
  }

  background.applyBadge(42, "unsupported");
  assert.equal(background.actionCalls.badgeTexts.at(-1)?.text, "");
  assert.equal(background.actionCalls.icons.at(-1)?.path?.[16], "icons/icon-16.png");
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
  background.applyBadge(42, "paused");
  assert.equal(background.actionCalls.badgeTexts.at(-1)?.text, "Ⅱ");
  assert.equal(background.actionCalls.badgeBackgroundColors.at(-1)?.color, "#F59E0B");
  assert.equal(background.actionCalls.badgeTextColors.at(-1)?.color, "#FFFFFF");
  assert.equal(background.actionCalls.icons.at(-1)?.path?.[16], "icons/icon-16.png");

  background.applyBadge(42, "stopped");
  assert.equal(background.actionCalls.badgeTexts.at(-1)?.text, "■");
  assert.equal(background.actionCalls.badgeBackgroundColors.at(-1)?.color, "#D92D43");
  assert.equal(background.actionCalls.icons.at(-1)?.path?.[16], "icons/icon-16.png");
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

async function run() {
  await testBadgeStylesDifferentiateMilestones();
  await testEveryStatusUsesNativeBadgeOnDefaultIcon();
  await testMilestoneJiraUsesDedicatedBadge();
  await testPendingAndActiveJiraUseRecordedBadge();
  await testPausedAndStoppedJiraUseDedicatedBadges();
  await testMergedRequirementMRPageUsesMergedBadge();
  await testUnrecordedPageUsesAddableBadge();
  await testIncompatibleNativeHostClearsBadge();
}

run().then(() => {
  console.log("background.behavior.test.js passed");
}).catch((error) => {
  console.error(error);
  process.exitCode = 1;
});

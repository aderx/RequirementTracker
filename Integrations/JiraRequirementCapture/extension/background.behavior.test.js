const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const backgroundSource = fs.readFileSync(path.join(__dirname, "background.js"), "utf8");

function eventStub() {
  return { addListener() {} };
}

function createBackground(nativeStub) {
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
        setBadgeText() {},
        setBadgeBackgroundColor() {},
        setBadgeTextColor() {}
      }
    }
  };

  const exposure = [
    "globalThis.__background = {",
    "  BADGE_STYLES,",
    "  resolveState,",
    "  setNativeMessageStub(stub) { sendNativeMessage = stub; }",
    "};"
  ].join("\n");
  vm.createContext(sandbox);
  vm.runInContext(backgroundSource + "\n" + exposure, sandbox);
  sandbox.__background.setNativeMessageStub(nativeStub);
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

async function testBadgeStylesDifferentiateCompletion() {
  const background = createBackground(nativeStubFor({ exists: true, status: "merged" }));
  assert.equal(background.BADGE_STYLES.recorded.text, "↻");
  assert.equal(background.BADGE_STYLES.completed?.text, "✓");
  assert.equal(
    background.BADGE_STYLES.completed?.color,
    background.BADGE_STYLES.recorded.color
  );
}

async function testMergedJiraUsesCompletedBadge() {
  const background = createBackground(nativeStubFor({ exists: true, status: "merged" }));
  assert.equal(
    await background.resolveState("http://jira.zstack.io/browse/ZSTAC-12345"),
    "completed"
  );
}

async function testIncompleteJiraUsesRecordedBadge() {
  const background = createBackground(nativeStubFor({ exists: true, status: "tested" }));
  assert.equal(
    await background.resolveState("http://jira.zstack.io/browse/ZSTAC-12345"),
    "recorded"
  );
}

async function testMergedRequirementMRPageUsesCompletedBadge() {
  const background = createBackground(nativeStubFor({ exists: true, status: "merged" }));
  assert.equal(
    await background.resolveState("http://gitlab.zstack.io/g/p/-/merge_requests/1"),
    "completed"
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
  await testBadgeStylesDifferentiateCompletion();
  await testMergedJiraUsesCompletedBadge();
  await testIncompleteJiraUsesRecordedBadge();
  await testMergedRequirementMRPageUsesCompletedBadge();
  await testUnrecordedPageUsesAddableBadge();
  await testIncompatibleNativeHostClearsBadge();
}

run().then(() => {
  console.log("background.behavior.test.js passed");
}).catch((error) => {
  console.error(error);
  process.exitCode = 1;
});

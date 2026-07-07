const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const popupPath = path.join(__dirname, "popup.js");
const popupSource = fs.readFileSync(popupPath, "utf8");

function createElement(id = "") {
  const classes = new Set();
  return {
    id,
    children: [],
    className: "",
    disabled: false,
    innerHTML: "",
    textContent: "",
    value: "",
    type: "",
    title: "",
    classList: {
      add: (...names) => names.forEach((name) => classes.add(name)),
      remove: (...names) => names.forEach((name) => classes.delete(name)),
      toggle: (name, force) => {
        if (force === undefined ? !classes.has(name) : force) {
          classes.add(name);
          return true;
        }

        classes.delete(name);
        return false;
      },
      contains: (name) => classes.has(name)
    },
    addEventListener(type, handler) {
      this[`on${type}`] = handler;
    },
    appendChild(child) {
      this.children.push(child);
      return child;
    },
    focus() {}
  };
}

function createPopupSandbox() {
  const elements = new Map();
  const document = {
    getElementById(id) {
      if (!elements.has(id)) {
        elements.set(id, createElement(id));
      }

      return elements.get(id);
    },
    createElement(tagName) {
      return createElement(tagName);
    },
    addEventListener() {}
  };

  const sandbox = {
    console,
    document,
    window: { close() {} },
    URL,
    setInterval: () => 1001,
    clearInterval() {},
    setTimeout: () => 1002,
    clearTimeout() {},
    chrome: {
      runtime: {
        lastError: null,
        sendNativeMessage() {},
        sendMessage() {}
      },
      tabs: {
        query() {},
        sendMessage() {}
      },
      scripting: {
        executeScript() {}
      }
    }
  };

  vm.createContext(sandbox);
  vm.runInContext(
    `${popupSource}
globalThis.__popup = {
  elements,
  handleJiraPage,
  handleMRPage,
  attachMRWithInspection,
  renderSummary,
  setActions,
  setStatus,
  showSuccess,
  showUnsupported,
  clearTimers,
  setNativeMessageStub(stub) { sendNativeMessage = stub; }
};`,
    sandbox
  );

  return sandbox.__popup;
}

function summaryRows(popup) {
  return popup.elements.summaryPanel.children.map((row) => ({
    label: row.children[0].textContent,
    value: row.children[1].textContent,
    hasCopyButton: row.children[1].children.some((child) => child.className.includes("copy-button"))
  }));
}

async function testUnsupportedCountdownLivesOnCloseButton() {
  const popup = createPopupSandbox();

  popup.showUnsupported();

  assert.equal(popup.elements.titleText.textContent, "此页面暂不支持");
  assert.equal(popup.elements.actions.children.length, 1);
  assert.equal(popup.elements.actions.children[0].textContent, "关闭（5s）");
  assert.equal(popup.elements.countdownText.textContent, "");
}

async function testExistingJiraOffersNextStatusButton() {
  const popup = createPopupSandbox();
  popup.setNativeMessageStub(async () => ({ ok: true, exists: true, status: "pending" }));

  await popup.handleJiraPage({
    issueKey: "ZSTAC-12345",
    title: "需求标题",
    jiraURL: "http://jira.zstack.io/browse/ZSTAC-12345"
  });

  assert.equal(popup.elements.titleText.textContent, "需求已记录");
  assert.equal(popup.elements.actions.children.length, 2);
  assert.equal(popup.elements.actions.children[0].textContent, "更新信息");
  assert.equal(popup.elements.actions.children[1].textContent, "转为开发中");

  const rows = summaryRows(popup);
  assert.equal(rows.length, 3);
  assert.equal(rows[0].label, "需求");
  assert.equal(rows[0].hasCopyButton, true);
  assert.equal(rows[2].label, "记录状态");
  assert.equal(rows[2].value, "待开发");
}

async function testExistingActiveJiraOffersDoneButton() {
  const popup = createPopupSandbox();
  popup.setNativeMessageStub(async () => ({ ok: true, exists: true, status: "active" }));

  await popup.handleJiraPage({
    issueKey: "ZSTAC-12345",
    title: "需求标题"
  });

  assert.equal(popup.elements.actions.children[1].textContent, "转为开发完成");
}

async function testMergedJiraHasOnlyUpdateButton() {
  const popup = createPopupSandbox();
  popup.setNativeMessageStub(async () => ({ ok: true, exists: true, status: "merged" }));

  await popup.handleJiraPage({
    issueKey: "ZSTAC-12345",
    title: "需求标题"
  });

  assert.equal(popup.elements.actions.children.length, 1);
  assert.equal(popup.elements.actions.children[0].textContent, "更新信息");
}

async function testNewJiraOffersAddButtons() {
  const popup = createPopupSandbox();
  popup.setNativeMessageStub(async () => ({ ok: true, exists: false }));

  await popup.handleJiraPage({
    issueKey: "ZSTAC-12345",
    title: "需求标题"
  });

  assert.equal(popup.elements.titleText.textContent, "添加这个需求？");
  assert.equal(popup.elements.actions.children.length, 2);
  assert.equal(popup.elements.actions.children[0].textContent, "添加");
  assert.equal(popup.elements.actions.children[1].textContent, "添加并开始开发");
  assert.equal(popup.elements.countdownText.textContent, "");
}

async function testMergedMRSyncsStatusAutomatically() {
  const popup = createPopupSandbox();
  const sent = [];
  popup.setNativeMessageStub(async (message) => {
    sent.push(message);
    if (message.type === "inspectRequirement") {
      return {
        ok: true,
        exists: true,
        status: "tested",
        mrURL: "http://gitlab.zstack.io/g/p/-/merge_requests/1"
      };
    }
    if (message.type === "attachMergeRequest") {
      return {
        ok: true,
        action: "synced",
        issueKey: "ZSTAC-12345",
        statusUpdated: true,
        targetStatus: "merged"
      };
    }
    return { ok: true };
  });

  await popup.handleMRPage({
    mrURL: "http://gitlab.zstack.io/g/p/-/merge_requests/1",
    mrState: "merged",
    jiraURL: "http://jira.zstack.io/browse/ZSTAC-12345",
    issueKey: "ZSTAC-12345"
  });

  assert.ok(sent.some((message) => message.type === "attachMergeRequest"));
  assert.equal(popup.elements.titleText.textContent, "完成");
  assert.equal(popup.elements.statusText.textContent, "MR 状态已同步，需求已转为已合并");
}

async function testRecordedMRWithoutChangeDoesNotWrite() {
  const popup = createPopupSandbox();
  const sent = [];
  popup.setNativeMessageStub(async (message) => {
    sent.push(message);
    return {
      ok: true,
      exists: true,
      status: "merged",
      mrURL: "http://gitlab.zstack.io/g/p/-/merge_requests/1"
    };
  });

  await popup.handleMRPage({
    mrURL: "http://gitlab.zstack.io/g/p/-/merge_requests/1",
    mrState: "merged",
    jiraURL: "http://jira.zstack.io/browse/ZSTAC-12345",
    issueKey: "ZSTAC-12345"
  });

  assert.ok(!sent.some((message) => message.type === "attachMergeRequest"));
  assert.equal(popup.elements.titleText.textContent, "MR 已记录");
  assert.equal(popup.elements.actions.children.length, 1);
  assert.equal(popup.elements.actions.children[0].textContent, "关闭（5s）");

  const rows = summaryRows(popup);
  assert.equal(rows[1].label, "MR 状态");
  assert.equal(rows[1].value, "已合并");
  assert.equal(rows[2].label, "记录状态");
  assert.equal(rows[2].value, "已合并");
}

async function testReplacePromptHasSingleReplaceButton() {
  const popup = createPopupSandbox();
  popup.setNativeMessageStub(async () => ({
    ok: true,
    exists: true,
    status: "active",
    mrURL: "http://gitlab.zstack.io/g/p/-/merge_requests/1"
  }));

  await popup.handleMRPage({
    mrURL: "http://gitlab.zstack.io/g/p/-/merge_requests/2",
    mrState: "open",
    jiraURL: "http://jira.zstack.io/browse/ZSTAC-12345",
    issueKey: "ZSTAC-12345"
  });

  assert.equal(popup.elements.titleText.textContent, "替换已有 MR？");
  assert.equal(popup.elements.actions.children.length, 1);
  assert.equal(popup.elements.actions.children[0].textContent, "替换");
}

async function testSuccessAutoClosesWithCountdown() {
  const popup = createPopupSandbox();

  popup.showSuccess("完成", "已添加到需求记录");

  assert.equal(popup.elements.actions.children.length, 1);
  assert.equal(popup.elements.actions.children[0].textContent, "关闭（5s）");
}

async function run() {
  await testUnsupportedCountdownLivesOnCloseButton();
  await testExistingJiraOffersNextStatusButton();
  await testExistingActiveJiraOffersDoneButton();
  await testMergedJiraHasOnlyUpdateButton();
  await testNewJiraOffersAddButtons();
  await testMergedMRSyncsStatusAutomatically();
  await testRecordedMRWithoutChangeDoesNotWrite();
  await testReplacePromptHasSingleReplaceButton();
  await testSuccessAutoClosesWithCountdown();
}

run().then(() => {
  console.log("popup.behavior.test.js passed");
}).catch((error) => {
  console.error(error);
  process.exitCode = 1;
});

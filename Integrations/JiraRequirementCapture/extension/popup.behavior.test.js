const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const popupPath = path.join(__dirname, "popup.js");
const popupSource = fs.readFileSync(popupPath, "utf8");
const popupCSS = fs.readFileSync(path.join(__dirname, "popup.css"), "utf8");

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
    replaceChildren(...children) { this.children = children; },
    setAttribute(name, value) { this[name] = value; },
    getAttribute(name) { return this[name]; },
    focus() {}
  };
}

function createPopupSandbox() {
  const elements = new Map();
  const badgeDraws = [];
  const clipboardWrites = [];
  const openedTabs = [];
  const popupState = { closedCount: 0 };
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
    BadgeIconRenderer: {
      styles: {
        addable: { color: "#FF9500" },
        recorded: { color: "#1F9D54" },
        done: { color: "#1570EF" },
        tested: { color: "#7F56D9" },
        merged: { color: "#1F9D54" },
        paused: { color: "#F59E0B" },
        stopped: { color: "#D92D43" }
      },
      drawBadgePreview(canvas, state) {
        badgeDraws.push({ canvas, state });
      }
    },
    navigator: {
      clipboard: {
        async writeText(value) {
          clipboardWrites.push(value);
        }
      }
    },
    window: {
      close() {
        popupState.closedCount += 1;
      }
    },
    URL,
    setInterval: () => 1001,
    clearInterval() {},
    setTimeout: () => 1002,
    clearTimeout() {},
    chrome: {
      runtime: {
        lastError: null,
        getURL(value) {
          return `chrome-extension://abcdefghijklmnopabcdefghijklmnop/${value}`;
        },
        sendNativeMessage() {},
        sendMessage() {}
      },
      tabs: {
        query() {},
        sendMessage() {},
        async create(options) {
          openedTabs.push(options);
          return { id: openedTabs.length };
        }
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
  handlePageResult,
  handleJiraPage,
  handleMRPage,
  attachMRWithInspection,
  testPageStateFromURL,
  showTestPageState,
  renderSummary,
  setActions,
  setStatus,
  showSuccess,
  showUnsupported,
  loadPluginSettings,
  clearTimers,
  setTabMessageStub(stub) { chrome.tabs.sendMessage = stub; },
  setNativeMessageStub(stub) { sendNativeMessage = stub; }
};`,
    sandbox
  );

  sandbox.__popup.badgeDraws = badgeDraws;
  sandbox.__popup.clipboardWrites = clipboardWrites;
  sandbox.__popup.openedTabs = openedTabs;
  sandbox.__popup.popupState = popupState;
  return sandbox.__popup;
}

function summaryRows(popup) {
  return popup.elements.summaryPanel.children.map((row) => ({
    label: row.children[0].textContent,
    value: row.children[1].textContent,
    hasCopyButton: row.children[1].children.some((child) => child.className.includes("copy-button")),
    hasOpenButton: row.children[1].children.some((child) => child.className.includes("open-button"))
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

async function testTestPageStateIsReadFromTheExtensionURL() {
  const popup = createPopupSandbox();
  assert.equal(
    popup.testPageStateFromURL(
      "chrome-extension://abcdefghijklmnopabcdefghijklmnop/test.html?state=tested"
    ),
    "tested"
  );
  assert.equal(
    popup.testPageStateFromURL(
      "chrome-extension://abcdefghijklmnopabcdefghijklmnop/test.html?state=unknown"
    ),
    "unsupported"
  );
  assert.equal(
    popup.testPageStateFromURL("https://example.com/?state=tested"),
    ""
  );
}

async function testTestPageStatesRenderIsolatedMockDetails() {
  const testCases = [
    ["unsupported", "此页面暂不支持", "不支持页面"],
    ["addable", "添加这个需求？", "未记录"],
    ["recorded", "需求已记录", "开发中"],
    ["done", "开发已完成", "开发完成"],
    ["tested", "已完成自测", "已自测"],
    ["merged", "需求已完成", "已合并"],
    ["paused", "需求已暂停", "已暂停"],
    ["stopped", "需求已停止", "已停止"]
  ];

  for (const [state, title, status] of testCases) {
    const popup = createPopupSandbox();
    popup.setNativeMessageStub(async () => {
      throw new Error("测试页不得读取或写入 App 数据");
    });

    popup.showTestPageState(state);

    assert.equal(popup.elements.titleText.textContent, title);
    assert.equal(popup.elements.statusText.textContent, "测试模式");
    assert.equal(popup.elements.actions.children.length, 1);
    assert.equal(popup.elements.actions.children[0].textContent, "关闭");
    if (state === "unsupported") {
      assert.equal(popup.badgeDraws.length, 0);
    } else {
      assert.equal(popup.badgeDraws.at(-1)?.state, state);
      assert.equal(popup.elements.iconFrame.className, "icon-frame badge");
      assert.equal(popup.elements.badgeIconCanvas.className, "badge-icon-canvas");
      assert.equal(popup.elements.statusIcon.className, "icon-symbol hidden");
    }

    const rows = summaryRows(popup);
    assert.equal(rows.length, 4);
    assert.deepEqual(
      rows.map((row) => [row.label, row.value]),
      [
        ["模拟需求", "DEMO-1001"],
        ["标题", "插件状态测试（模拟数据）"],
        ["记录状态", status],
        ["数据来源", "独立模拟数据，不写入 App"]
      ]
    );
  }
}

async function testPausedAndStoppedTestStatesShowMockReasons() {
  for (const [state, label, reason] of [
    ["paused", "暂停原因", "等待测试依赖恢复"],
    ["stopped", "停止原因", "需求范围已调整"]
  ]) {
    const popup = createPopupSandbox();
    popup.showTestPageState(state);
    assert.equal(popup.elements.statusReasonPanel.className, `reason-card ${state}`);
    assert.equal(popup.elements.statusReasonLabel.textContent, label);
    assert.equal(popup.elements.statusReasonText.textContent, reason);
  }
}

async function testIncompatibleNativeHostIsRejectedAtStartup() {
  const popup = createPopupSandbox();
  popup.setNativeMessageStub(async () => ({
    ok: true,
    settings: {}
  }));

  const result = await popup.loadPluginSettings();

  assert.match(result.hostError, /Native Host.*版本过旧/);
  await popup.handlePageResult(
    { pageType: "jira", payload: {} },
    result.hostError
  );
  assert.match(popup.elements.statusText.textContent, /Native Host.*版本过旧/);
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

async function testExistingJiraOffersCopyAndOpenForLatestMR() {
  const popup = createPopupSandbox();
  const mrURL = "http://gitlab.zstack.io/g/p/-/merge_requests/88";
  popup.setNativeMessageStub(async () => ({
    ok: true,
    exists: true,
    status: "active",
    jiraURL: "http://jira.zstack.io/browse/ZSTAC-12345",
    mrURL
  }));

  await popup.handleJiraPage({
    issueKey: "ZSTAC-12345",
    title: "需求标题",
    jiraURL: "http://jira.zstack.io/browse/ZSTAC-12345"
  });

  const rows = summaryRows(popup);
  assert.deepEqual(rows.map((row) => row.label), ["需求", "标题", "MR", "记录状态"]);
  assert.equal(rows[2].value, "!88");
  assert.equal(rows[2].hasCopyButton, true);
  assert.equal(rows[2].hasOpenButton, true);

  const mrActions = popup.elements.summaryPanel.children[2].children[1].children;
  await mrActions.find((element) => element.className === "copy-button").onclick();
  assert.deepEqual(popup.clipboardWrites, [mrURL]);

  await mrActions.find((element) => element.className === "open-button").onclick();
  assert.equal(popup.openedTabs.length, 1);
  assert.equal(popup.openedTabs[0].url, mrURL);
  assert.equal(popup.openedTabs[0].active, true);
  assert.equal(popup.popupState.closedCount, 1);
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

async function testPausedAndStoppedJiraShowReason() {
  for (const testCase of [
    {
      status: "paused",
      reason: "等待后端接口",
      title: "需求已暂停",
      tone: "warning",
      icon: "pause",
      reasonLabel: "暂停原因"
    },
    {
      status: "stopped",
      reason: "公共组件影响范围过大",
      title: "需求已停止",
      tone: "error",
      icon: "stop",
      reasonLabel: "停止原因"
    }
  ]) {
    const popup = createPopupSandbox();
    popup.setNativeMessageStub(async () => ({
      ok: true,
      exists: true,
      status: testCase.status,
      pauseReason: testCase.reason
    }));

    await popup.handleJiraPage({
      issueKey: "ZSTAC-12345",
      title: "需求标题"
    });

    assert.equal(popup.elements.titleText.textContent, testCase.title);
    assert.equal(popup.elements.iconFrame.className, "icon-frame badge");
    assert.equal(popup.elements.badgeIconCanvas.className, "badge-icon-canvas");
    assert.equal(popup.badgeDraws.at(-1)?.state, testCase.status);
    assert.equal(popup.elements.statusIcon.className, "icon-symbol hidden");
    assert.equal(popup.elements.statusIcon.textContent, "");
    assert.equal(popup.elements.actions.children.length, 3);
    assert.equal(popup.elements.actions.children[0].textContent, "更新信息");
    assert.equal(popup.elements.actions.children[1].textContent, "转为待开发");
    assert.equal(popup.elements.actions.children[2].textContent, "开始开发");

    const rows = summaryRows(popup);
    assert.equal(rows.length, 3);
    assert.equal(popup.elements.statusReasonPanel.className, `reason-card ${testCase.status}`);
    assert.equal(popup.elements.statusReasonLabel.textContent, testCase.reasonLabel);
    assert.equal(popup.elements.statusReasonText.textContent, testCase.reason);
  }
}

async function testStatusToneCSSKeepsLargeIconsWhiteAndReasonCardsAligned() {
  assert.match(popupCSS, /#statusText\.success\s*\{/);
  assert.match(popupCSS, /#statusText\.error\s*\{/);
  assert.doesNotMatch(popupCSS, /(?:^|\n)\.error\s*\{/);

  const stoppedRule = popupCSS.match(/\.reason-card\.stopped\s*\{([^}]*)\}/)?.[1] || "";
  assert.doesNotMatch(stoppedRule, /box-shadow/);
}

async function testPausedJiraAlwaysShowsReasonRow() {
  const popup = createPopupSandbox();
  popup.setNativeMessageStub(async () => ({
    ok: true,
    exists: true,
    status: "paused",
    pauseReason: ""
  }));

  await popup.handleJiraPage({
    issueKey: "ZSTAC-12345",
    title: "需求标题"
  });

  assert.equal(popup.elements.statusReasonPanel.className, "reason-card paused");
  assert.equal(popup.elements.statusReasonLabel.textContent, "暂停原因");
  assert.equal(popup.elements.statusReasonText.textContent, "未填写");
}

async function testMergedJiraOffersExplicitReopenActions() {
  const popup = createPopupSandbox();
  popup.setNativeMessageStub(async () => ({ ok: true, exists: true, status: "merged" }));

  await popup.handleJiraPage({
    issueKey: "ZSTAC-12345",
    title: "需求标题"
  });

  assert.equal(popup.elements.actions.children.length, 3);
  assert.equal(popup.elements.actions.children[0].textContent, "更新信息");
  assert.equal(popup.elements.actions.children[1].textContent, "转为待开发");
  assert.equal(popup.elements.actions.children[2].textContent, "开始开发");
}

async function testReopenAndUpdateSendDifferentIntent() {
  for (const [actionIndex, targetStatus, reopen] of [[0, "", false], [1, "pending", true], [2, "active", true]]) {
    const popup = createPopupSandbox();
    const sent = [];
    popup.setNativeMessageStub(async (message) => {
      sent.push(message);
      return { ok: true, exists: true, status: "merged", action: "updated", statusUpdated: reopen, targetStatus };
    });
    await popup.handleJiraPage({ issueKey: "ZSTAC-12345", title: "重新打开后的标题" });
    assert.equal(sent.filter((message) => message.type === "upsertJiraRequirement").length, 0);
    await popup.elements.actions.children[actionIndex].onclick();
    const saved = sent.find((message) => message.type === "upsertJiraRequirement");
    assert.equal(saved.payload.targetStatus, targetStatus);
    assert.equal(saved.payload.reopen, reopen);
    assert.equal(saved.payload.title, "重新打开后的标题");
  }
}

async function testDoneAndTestedJiraOfferReopenActions() {
  for (const status of ["done", "tested"]) {
    const popup = createPopupSandbox();
    popup.setNativeMessageStub(async () => ({ ok: true, exists: true, status }));

    await popup.handleJiraPage({
      issueKey: "ZSTAC-12345",
      title: "需求标题"
    });

    assert.equal(popup.elements.actions.children.length, 3);
    assert.equal(popup.elements.actions.children[0].textContent, "更新信息");
  }
}

async function testNewJiraOffersAddButtons() {
  const popup = createPopupSandbox();
  popup.setNativeMessageStub(async () => ({ ok: true, exists: false }));

  await popup.handleJiraPage({
    issueKey: "ZSTAC-12345",
    title: "需求标题"
  });

  assert.equal(popup.elements.titleText.textContent, "添加这个需求？");
  assert.equal(popup.badgeDraws.at(-1)?.state, "addable");
  assert.equal(popup.elements.iconFrame.className, "icon-frame badge");
  assert.equal(popup.elements.actions.children.length, 2);
  assert.equal(popup.elements.actions.children[0].textContent, "添加");
  assert.equal(popup.elements.actions.children[1].textContent, "添加并开始开发");
  assert.equal(popup.elements.countdownText.textContent, "");
}

async function testMergedMRRequiresButtonBeforeStatusSync() {
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

  assert.ok(!sent.some((message) => message.type === "attachMergeRequest"));
  assert.equal(popup.elements.actions.children.length, 1);
  assert.equal(popup.elements.actions.children[0].textContent, "转为已合并");

  await popup.elements.actions.children[0].onclick();

  const attachMessage = sent.find((message) => message.type === "attachMergeRequest");
  assert.equal(attachMessage.payload.targetStatus, "merged");
  assert.equal(popup.elements.titleText.textContent, "完成");
  assert.equal(popup.elements.statusText.textContent, "MR 状态已同步，需求已转为已合并");
}

async function testOpenMRRequiresButtonBeforeStatusSync() {
  const popup = createPopupSandbox();
  const sent = [];
  popup.setNativeMessageStub(async (message) => {
    sent.push(message);
    if (message.type === "inspectRequirement") {
      return {
        ok: true,
        exists: true,
        status: "active",
        mrURL: "http://gitlab.zstack.io/g/p/-/merge_requests/1"
      };
    }
    return {
      ok: true,
      action: "attached",
      issueKey: "ZSTAC-12345",
      statusUpdated: true,
      targetStatus: "tested"
    };
  });

  await popup.handleMRPage({
    mrURL: "http://gitlab.zstack.io/g/p/-/merge_requests/2",
    mrState: "open",
    jiraURL: "http://jira.zstack.io/browse/ZSTAC-12345",
    issueKey: "ZSTAC-12345"
  });

  assert.ok(!sent.some((message) => message.type === "attachMergeRequest"));
  assert.equal(popup.elements.actions.children.length, 1);
  assert.equal(popup.elements.actions.children[0].textContent, "转为已自测");

  await popup.elements.actions.children[0].onclick();

  const attachMessage = sent.find((message) => message.type === "attachMergeRequest");
  assert.equal(attachMessage.payload.targetStatus, "tested");
  assert.equal(attachMessage.payload.replaceExisting, undefined);
}

async function testNewMRWithoutAvailableTransitionOffersSaveOnly() {
  const popup = createPopupSandbox();
  const sent = [];
  popup.setNativeMessageStub(async (message) => {
    sent.push(message);
    if (message.type === "inspectRequirement") {
      return {
        ok: true,
        exists: true,
        status: "merged",
        mrURL: "http://gitlab.zstack.io/g/p/-/merge_requests/1",
        mrHistory: []
      };
    }
    return {
      ok: true,
      action: "attached",
      issueKey: "ZSTAC-12345",
      statusUpdated: false
    };
  });

  await popup.handleMRPage({
    mrURL: "http://gitlab.zstack.io/g/p/-/merge_requests/2",
    mrState: "open",
    jiraURL: "http://jira.zstack.io/browse/ZSTAC-12345",
    issueKey: "ZSTAC-12345"
  });

  assert.equal(popup.elements.actions.children.length, 1);
  assert.equal(popup.elements.actions.children[0].textContent, "保存 MR");
  assert.ok(!sent.some((message) => message.type === "attachMergeRequest"));

  await popup.elements.actions.children[0].onclick();

  const attachMessage = sent.find((message) => message.type === "attachMergeRequest");
  assert.equal(attachMessage.payload.targetStatus, "");
}

async function testRecordedMergedMRShowsTerminalCompletion() {
  const popup = createPopupSandbox();
  const sent = [];
  popup.setNativeMessageStub(async (message) => {
    sent.push(message);
    return {
      ok: true,
      exists: true,
      status: "merged",
      mrURL: "http://gitlab.zstack.io/g/p/-/merge_requests/2",
      mrHistory: ["http://gitlab.zstack.io/g/p/-/merge_requests/1"]
    };
  });

  await popup.handleMRPage({
    mrURL: "http://gitlab.zstack.io/g/p/-/merge_requests/1",
    mrState: "merged",
    jiraURL: "http://jira.zstack.io/browse/ZSTAC-12345",
    issueKey: "ZSTAC-12345"
  });

  assert.ok(!sent.some((message) => message.type === "attachMergeRequest"));
  assert.equal(popup.elements.titleText.textContent, "需求已完成");
  assert.equal(popup.elements.statusText.textContent, "MR 与需求均为已合并状态");
  assert.equal(popup.badgeDraws.at(-1)?.state, "merged");
  assert.equal(popup.elements.iconFrame.className, "icon-frame badge");
  assert.equal(popup.elements.statusIcon.className, "icon-symbol hidden");
  assert.equal(popup.elements.actions.children.length, 1);
  assert.equal(popup.elements.actions.children[0].textContent, "关闭");

  const rows = summaryRows(popup);
  assert.equal(rows[1].label, "MR 状态");
  assert.equal(rows[1].value, "已合并");
  assert.equal(rows[2].label, "记录状态");
  assert.equal(rows[2].value, "已合并");
}

async function testMRPageOffersCopyAndOpenForJira() {
  const popup = createPopupSandbox();
  const jiraURL = "http://jira.zstack.io/browse/ZSTAC-12345";
  popup.setNativeMessageStub(async () => ({
    ok: true,
    exists: true,
    status: "active",
    jiraURL,
    mrURL: "http://gitlab.zstack.io/g/p/-/merge_requests/1"
  }));

  await popup.handleMRPage({
    mrURL: "http://gitlab.zstack.io/g/p/-/merge_requests/1",
    mrState: "closed",
    jiraURL,
    issueKey: "ZSTAC-12345"
  });

  const rows = summaryRows(popup);
  assert.equal(rows[0].label, "需求");
  assert.equal(rows[0].hasCopyButton, true);
  assert.equal(rows[0].hasOpenButton, true);

  const jiraActions = popup.elements.summaryPanel.children[0].children[1].children;
  await jiraActions.find((element) => element.className === "copy-button").onclick();
  assert.deepEqual(popup.clipboardWrites, [jiraURL]);

  await jiraActions.find((element) => element.className === "open-button").onclick();
  assert.equal(popup.openedTabs.length, 1);
  assert.equal(popup.openedTabs[0].url, jiraURL);
  assert.equal(popup.openedTabs[0].active, true);
  assert.equal(popup.popupState.closedCount, 1);
}

async function testSuccessAutoClosesWithCountdown() {
  const popup = createPopupSandbox();

  popup.showSuccess("完成", "已添加到需求记录");

  assert.equal(popup.elements.actions.children.length, 1);
  assert.equal(popup.elements.actions.children[0].textContent, "关闭（5s）");
}

async function testMRWithoutPageJiraReusesSavedBinding() {
  const mrURL = "http://gitlab.zstack.io/g/p/-/merge_requests/1";
  const jiraURL = "http://jira.zstack.io/browse/ZSTAC-12345";
  for (const historical of [false, true]) {
    const popup = createPopupSandbox();
    const sent = [];
    popup.setNativeMessageStub(async (message) => {
      sent.push(message);
      if (message.type === "inspectByURL") {
        assert.equal(message.payload.mrURL, mrURL);
        return { ok: true, exists: true, issueKey: "ZSTAC-12345", jiraURL };
      }
      assert.equal(message.type, "inspectRequirement");
      assert.equal(message.payload.issueKey, "ZSTAC-12345");
      assert.equal(message.payload.jiraURL, jiraURL);
      return {
        ok: true,
        exists: true,
        status: "tested",
        mrURL: historical ? "http://gitlab.zstack.io/g/p/-/merge_requests/2" : mrURL,
        mrHistory: historical ? [mrURL] : []
      };
    });

    await popup.handleMRPage({ mrURL: `${mrURL}?view=parallel#note_10`, mrState: "open" });

    assert.equal(popup.elements.titleText.textContent, "MR 已记录");
    assert.equal(popup.elements.manualPanel.classList.contains("hidden"), true);
    assert.equal(summaryRows(popup)[0].value, "ZSTAC-12345");
    assert.deepEqual(sent.map((message) => message.type), ["inspectByURL", "inspectRequirement"]);
  }
}

async function testRecoveredMRBindingStillRequiresClickToSyncStatus() {
  const popup = createPopupSandbox();
  const mrURL = "http://gitlab.zstack.io/g/p/-/merge_requests/1";
  const sent = [];
  popup.setNativeMessageStub(async (message) => {
    sent.push(message);
    if (message.type === "inspectByURL") {
      return { ok: true, exists: true, issueKey: "ZSTAC-12345" };
    }
    if (message.type === "inspectRequirement") {
      return { ok: true, exists: true, status: "tested", mrURL };
    }
    return { ok: true, action: "synced", statusUpdated: true, targetStatus: "merged" };
  });

  await popup.handleMRPage({ mrURL, mrState: "merged" });
  assert.equal(popup.elements.titleText.textContent, "同步 MR 状态");
  assert.equal(popup.elements.actions.children[0].textContent, "转为已合并");
  assert.ok(!sent.some((message) => message.type === "attachMergeRequest"));

  await popup.elements.actions.children[0].onclick();
  const saved = sent.find((message) => message.type === "attachMergeRequest");
  assert.equal(saved.payload.issueKey, "ZSTAC-12345");
  assert.equal(saved.payload.mrURL, mrURL);
  assert.equal(saved.payload.targetStatus, "merged");
}

async function testUnboundMRStillRequestsJiraAndLookupErrorsAreReported() {
  const popup = createPopupSandbox();
  const payload = { mrURL: "http://gitlab.zstack.io/g/p/-/merge_requests/1", mrState: "open" };
  popup.setNativeMessageStub(async () => ({ ok: true, exists: false }));
  await popup.handleMRPage(payload);
  assert.equal(popup.elements.titleText.textContent, "关联 Jira");
  assert.equal(popup.elements.manualPanel.classList.contains("hidden"), false);

  const failedPopup = createPopupSandbox();
  failedPopup.setNativeMessageStub(async () => ({ ok: false, error: "读取需求失败" }));
  await assert.rejects(() => failedPopup.handleMRPage(payload), /读取需求失败/);
}

async function testManualStatusActionsRequireReasonsAndPreserveFailures() {
  const popup = createPopupSandbox();
  const writes = [];
  const record = { ok: true, exists: true, issueKey: "ZSTAC-12345", status: "active", supportsStatusActions: true, hasMR: false };
  let failure = false;
  popup.setNativeMessageStub(async (message) => {
    if (message.type === "inspectRequirement") return record;
    writes.push(message);
    return failure ? { ok: false, error: "需求状态已变化" } : { ok: true };
  });
  const action = (text) => popup.elements.actions.children.find((element) => element.textContent === text);
  const menuItem = (text) => popup.elements.statusMenuItems.children.find((element) => element.textContent === text);
  await popup.handleJiraPage({ issueKey: record.issueKey });
  assert.equal(popup.elements.statusMenuContainer.classList.contains("hidden"), false);
  assert.ok(menuItem("暂停") && menuItem("停止") && menuItem("一键完成"));
  assert.equal(action("暂停"), undefined, "Status actions belong in the header menu");
  await popup.elements.statusMenuButton.onclick();
  assert.equal(popup.elements.statusMenuButton["aria-expanded"], "true");
  await menuItem("暂停").onclick();
  assert.equal(popup.elements.statusMenuButton["aria-expanded"], "false");
  assert.equal(popup.badgeDraws.at(-1).state, "paused");
  await action("确认暂停").onclick();
  assert.equal(writes.length, 0, "Blank reason must not write");
  assert.match(popup.elements.statusText.textContent, /请填写暂停原因/);
  popup.elements.statusActionReason.value = "  等待后端确认  ";
  failure = true;
  await action("确认暂停").onclick();
  assert.equal(popup.elements.statusActionReason.value, "  等待后端确认  ");
  assert.match(popup.elements.statusText.textContent, /需求状态已变化/);
  assert.equal(popup.badgeDraws.at(-1).state, "paused", "A save error must preserve the target status icon");
  assert.equal(writes[0].type, "updateRequirementStatus");
  assert.equal(writes[0].payload.reason, "等待后端确认");
  assert.equal(writes[0].payload.expectedStatus, "active");
  await action("取消").onclick();
  assert.ok(menuItem("一键完成"));
  await menuItem("一键完成").onclick();
  await action("确认一键完成").onclick();
  assert.equal(writes.length, 1, "Completion without MR needs a note");
  popup.elements.statusActionReason.value = "配置调整完成，无需 MR";
  failure = false;
  await action("确认一键完成").onclick();
  assert.equal(writes.at(-1).payload.targetStatus, "merged");
  assert.equal(popup.elements.statusActionPanel.classList.contains("hidden"), true);
  assert.equal(popup.badgeDraws.at(-1).state, "merged", "Saved status must use the same icon as its form");

  for (const status of ["pending", "active", "done", "tested", "paused", "stopped", "merged"]) {
    record.status = status;
    await popup.handleJiraPage({ issueKey: record.issueKey });
    assert.equal(popup.elements.statusMenuItems.children.length, 3);
    for (const [label, target] of [["暂停", "paused"], ["停止", "stopped"], ["一键完成", "merged"]]) {
      assert.equal(menuItem(target === status ? `${label}（当前）` : label).disabled, target === status);
      if (target !== status) {
        await menuItem(label).onclick();
        assert.equal(popup.badgeDraws.at(-1).state, target, `${status} → ${target} must use the toolbar status renderer`);
        await action("取消").onclick();
      }
    }
  }
  await menuItem("暂停").onclick();
  record.status = "active";
  record.hasMR = true;
  record.note = "旧完成说明";
  await popup.handleJiraPage({ issueKey: record.issueKey });
  await menuItem("一键完成").onclick();
  const count = writes.length;
  assert.equal(popup.elements.statusActionReason.value, "", "A transition needs its own explanation");
  await action("确认一键完成").onclick();
  assert.equal(writes.length, count, "An MR does not replace a manual completion explanation");

  record.supportsStatusActions = false;
  await popup.handleJiraPage({ issueKey: record.issueKey });
  assert.ok(popup.elements.statusMenuItems.children.every((item) => item.disabled));
  assert.equal(popup.elements.statusMenuHint.classList.contains("hidden"), false);
  assert.match(popup.elements.statusMenuHint.textContent, /版本较旧/);

  record.exists = false;
  await popup.handleJiraPage({ issueKey: record.issueKey });
  assert.equal(popup.elements.statusMenuContainer.classList.contains("hidden"), true);
}

async function testListVisibilityUsesOnlyCurrentDocumentAndPreservesFailures() {
  let enabled = true;
  let failWrite = false;
  const messages = [];
  const tabMessage = async (tabId, message) => {
    assert.equal(tabId, 42, "The switch only targets the active Jira list tab");
    messages.push(message);
    if (message.type === "SET_REQUIREMENT_LIST_VISIBILITY") {
      if (failWrite) throw new Error("页面连接已断开");
      enabled = message.enabled;
    }
    return { ok: true, enabled };
  };
  const popup = createPopupSandbox();
  popup.setTabMessageStub(tabMessage);
  await popup.handlePageResult({ pageType: "jira-list" }, null, 42);
  const toggle = popup.elements.listVisibilitySwitch;
  assert.equal(popup.elements.listVisibilityPanel.classList.contains("hidden"), false);
  assert.equal(toggle["aria-checked"], "true");
  await toggle.onclick();
  assert.equal(enabled, false);
  assert.equal(toggle["aria-checked"], "false");
  assert.match(popup.elements.statusText.textContent, /刷新后恢复开启/);

  const reopened = createPopupSandbox();
  reopened.setTabMessageStub(tabMessage);
  await reopened.handlePageResult({ pageType: "jira-list" }, null, 42);
  assert.equal(reopened.elements.listVisibilitySwitch["aria-checked"], "false");
  failWrite = true;
  await reopened.elements.listVisibilitySwitch.onclick();
  assert.equal(reopened.elements.listVisibilitySwitch["aria-checked"], "false", "Failed toggles keep the actual page state");
  assert.equal(reopened.elements.listVisibilitySwitch.disabled, false);
  assert.match(reopened.elements.statusText.textContent, /页面连接已断开/);
  failWrite = false;
  await reopened.elements.listVisibilitySwitch.onclick();
  assert.equal(enabled, true);
  assert.equal(reopened.elements.listVisibilitySwitch["aria-checked"], "true");
  assert.deepEqual(messages.map((message) => message.type), [
    "GET_REQUIREMENT_LIST_VISIBILITY", "SET_REQUIREMENT_LIST_VISIBILITY",
    "GET_REQUIREMENT_LIST_VISIBILITY", "SET_REQUIREMENT_LIST_VISIBILITY", "SET_REQUIREMENT_LIST_VISIBILITY"
  ]);
  reopened.showUnsupported();
  assert.equal(reopened.elements.listVisibilityPanel.classList.contains("hidden"), true);
}

async function run() {
  await testListVisibilityUsesOnlyCurrentDocumentAndPreservesFailures();
  await testManualStatusActionsRequireReasonsAndPreserveFailures();
  await testUnsupportedCountdownLivesOnCloseButton();
  await testTestPageStateIsReadFromTheExtensionURL();
  await testTestPageStatesRenderIsolatedMockDetails();
  await testPausedAndStoppedTestStatesShowMockReasons();
  await testIncompatibleNativeHostIsRejectedAtStartup();
  await testExistingJiraOffersNextStatusButton();
  await testExistingJiraOffersCopyAndOpenForLatestMR();
  await testExistingActiveJiraOffersDoneButton();
  await testPausedAndStoppedJiraShowReason();
  await testStatusToneCSSKeepsLargeIconsWhiteAndReasonCardsAligned();
  await testPausedJiraAlwaysShowsReasonRow();
  await testMergedJiraOffersExplicitReopenActions();
  await testReopenAndUpdateSendDifferentIntent();
  await testDoneAndTestedJiraOfferReopenActions();
  await testNewJiraOffersAddButtons();
  await testMergedMRRequiresButtonBeforeStatusSync();
  await testOpenMRRequiresButtonBeforeStatusSync();
  await testNewMRWithoutAvailableTransitionOffersSaveOnly();
  await testRecordedMergedMRShowsTerminalCompletion();
  await testMRPageOffersCopyAndOpenForJira();
  await testMRWithoutPageJiraReusesSavedBinding();
  await testRecoveredMRBindingStillRequiresClickToSyncStatus();
  await testUnboundMRStillRequestsJiraAndLookupErrorsAreReported();
  await testSuccessAutoClosesWithCountdown();
}

run().then(() => {
  console.log("popup.behavior.test.js passed");
}).catch((error) => {
  console.error(error);
  process.exitCode = 1;
});

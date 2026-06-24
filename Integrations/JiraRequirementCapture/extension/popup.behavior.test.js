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
        sendNativeMessage() {}
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

async function testUnsupportedCountdownLivesOnCloseButton() {
  const popup = createPopupSandbox();

  popup.showUnsupported("当前页面暂不支持");

  assert.equal(popup.elements.actions.children.length, 1);
  assert.equal(popup.elements.actions.children[0].textContent, "关闭（5s）");
  assert.equal(popup.elements.countdownText.textContent, "");
}

async function testExistingJiraDefaultsToIgnoreForFiveSeconds() {
  const popup = createPopupSandbox();
  popup.setNativeMessageStub(async () => ({ ok: true, exists: true }));

  await popup.handleJiraPage({
    issueKey: "ZSTAC-12345",
    title: "需求标题"
  });

  assert.equal(popup.elements.actions.children.length, 3);
  assert.equal(popup.elements.actions.children[0].textContent, "忽略（5s）");
  assert.equal(popup.elements.actions.children[1].textContent, "更新");
  assert.equal(popup.elements.actions.children[2].textContent, "确认并开始开发");
  assert.equal(popup.elements.countdownText.textContent, "");
}

async function testNewJiraDefaultsToAddForFiveSeconds() {
  const popup = createPopupSandbox();
  popup.setNativeMessageStub(async () => ({ ok: true, exists: false }));

  await popup.handleJiraPage({
    issueKey: "ZSTAC-12345",
    title: "需求标题"
  });

  assert.equal(popup.elements.actions.children.length, 3);
  assert.equal(popup.elements.actions.children[0].textContent, "取消");
  assert.equal(popup.elements.actions.children[1].textContent, "添加（5s）");
  assert.equal(popup.elements.actions.children[2].textContent, "确认并开始开发");
  assert.equal(popup.elements.countdownText.textContent, "");
}

async function testSuccessClosesAfterTwoSeconds() {
  const popup = createPopupSandbox();

  popup.showSuccess("已保存", "需求记录已更新到 App");

  assert.equal(popup.elements.actions.children.length, 1);
  assert.equal(popup.elements.actions.children[0].textContent, "关闭（2s）");
  assert.equal(popup.elements.countdownText.textContent, "");
}

async function run() {
  await testUnsupportedCountdownLivesOnCloseButton();
  await testExistingJiraDefaultsToIgnoreForFiveSeconds();
  await testNewJiraDefaultsToAddForFiveSeconds();
  await testSuccessClosesAfterTwoSeconds();
}

run().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});

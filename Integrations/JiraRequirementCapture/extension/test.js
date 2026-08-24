const HOST_NAME = "com.aderx.requirementtracker.jira_capture";
const REQUIRED_NATIVE_HOST_PROTOCOL_VERSION = 3;
const TEST_STATES = [
  { id: "unsupported", label: "不支持页面" },
  { id: "addable", label: "可添加" },
  { id: "recorded", label: "已记录" },
  { id: "done", label: "开发完成" },
  { id: "tested", label: "已自测" },
  { id: "merged", label: "已合并" },
  { id: "paused", label: "已暂停" },
  { id: "stopped", label: "已停止" }
];

const elements = {
  stateButtons: document.getElementById("stateButtons"),
  applyResult: document.getElementById("applyResult"),
  refreshBindingButton: document.getElementById("refreshBindingButton"),
  bindingDot: document.getElementById("bindingDot"),
  bindingState: document.getElementById("bindingState"),
  extensionVersion: document.getElementById("extensionVersion"),
  extensionID: document.getElementById("extensionID"),
  nativeHostName: document.getElementById("nativeHostName"),
  protocolVersion: document.getElementById("protocolVersion"),
  jiraBaseURL: document.getElementById("jiraBaseURL"),
  mrHosts: document.getElementById("mrHosts")
};

document.addEventListener("DOMContentLoaded", initialize);

async function initialize() {
  renderStateButtons();
  elements.refreshBindingButton.addEventListener("click", refreshBindingInformation);

  const initialState = stateFromURL();
  await applyState(initialState, { updateURL: false, announce: false });
  await refreshBindingInformation();
}

function renderStateButtons() {
  elements.stateButtons.replaceChildren(
    ...TEST_STATES.map((state) => {
      const button = document.createElement("button");
      button.type = "button";
      button.className = "state-button";
      button.dataset.state = state.id;
      button.textContent = state.label;
      button.addEventListener("click", () => applyState(state.id));
      return button;
    })
  );
}

async function applyState(state, { updateURL = true, announce = true } = {}) {
  const selectedState = TEST_STATES.find((candidate) => candidate.id === state) ?? TEST_STATES[0];

  if (updateURL) {
    const url = new URL(window.location.href);
    url.searchParams.set("state", selectedState.id);
    window.history.replaceState({}, "", url);
  }

  for (const button of elements.stateButtons.querySelectorAll(".state-button")) {
    button.classList.toggle("selected", button.dataset.state === selectedState.id);
  }
  try {
    const tab = await currentTab();
    const response = await sendRuntimeMessage({
      type: "APPLY_TEST_PAGE_STATE",
      url: window.location.href,
      tabId: tab?.id
    });
    if (!response?.ok || response.state !== selectedState.id) {
      throw new Error(response?.error || "插件后台返回的状态不一致");
    }
    setApplyResult(
      announce
        ? `工具栏已切换：${selectedState.label}`
        : `当前状态：${selectedState.label}`
    );
  } catch (error) {
    setApplyResult(friendlyRuntimeError(error), "danger");
  }
}

async function refreshBindingInformation() {
  const manifest = chrome.runtime.getManifest();
  elements.extensionVersion.textContent = manifest.version || "—";
  elements.extensionID.textContent = chrome.runtime.id || "—";
  elements.nativeHostName.textContent = HOST_NAME;
  elements.bindingState.textContent = "检查中…";
  setBindingTone("neutral");

  try {
    const response = await sendNativeMessage({ type: "getPluginSettings", payload: {} });
    if (!response?.ok) {
      throw new Error(response?.error || "Native Host 返回失败");
    }

    const protocolVersion = Number(response.protocolVersion || 0);
    const compatible = protocolVersion >= REQUIRED_NATIVE_HOST_PROTOCOL_VERSION;
    const settings = response.settings || {};
    elements.protocolVersion.textContent = `${protocolVersion}（要求 ≥ ${REQUIRED_NATIVE_HOST_PROTOCOL_VERSION}）`;
    elements.jiraBaseURL.textContent = settings.jiraBaseURL || "未配置";
    elements.mrHosts.textContent = Array.isArray(settings.mrHosts) && settings.mrHosts.length
      ? settings.mrHosts.join("、")
      : "未配置";

    if (!compatible) {
      elements.bindingState.textContent = "协议版本过低";
      setBindingTone("danger");
      return;
    }

    elements.bindingState.textContent = "已连接";
    setBindingTone("success");
  } catch {
    elements.protocolVersion.textContent = `未知（要求 ≥ ${REQUIRED_NATIVE_HOST_PROTOCOL_VERSION}）`;
    elements.jiraBaseURL.textContent = "无法读取";
    elements.mrHosts.textContent = "无法读取";
    elements.bindingState.textContent = "未连接，请重新安装 Native Host";
    setBindingTone("danger");
  }
}

function setApplyResult(message, tone = "success") {
  elements.applyResult.textContent = message;
  elements.applyResult.className = `result-text ${tone}`;
}

function friendlyRuntimeError(error) {
  const message = String(error?.message || "");
  if (/message port closed|receiving end does not exist|could not establish connection/i.test(message)) {
    return "切换失败：请在扩展管理页重新加载插件后重试";
  }
  if (/^[\u4e00-\u9fff]/.test(message)) {
    return `切换失败：${message}`;
  }
  return "切换失败：插件后台未响应，请重试";
}

function setBindingTone(tone) {
  elements.bindingDot.className = `status-dot ${tone}`;
}

function stateFromURL() {
  const state = new URL(window.location.href).searchParams.get("state") || "unsupported";
  return TEST_STATES.some((candidate) => candidate.id === state) ? state : "unsupported";
}

function currentTab() {
  return new Promise((resolve) => {
    chrome.tabs.getCurrent((tab) => {
      void chrome.runtime.lastError;
      resolve(tab);
    });
  });
}

function sendRuntimeMessage(message) {
  return new Promise((resolve, reject) => {
    chrome.runtime.sendMessage(message, (response) => {
      const error = chrome.runtime.lastError;
      if (error) {
        reject(new Error(error.message));
        return;
      }
      resolve(response);
    });
  });
}

function sendNativeMessage(message) {
  return new Promise((resolve, reject) => {
    chrome.runtime.sendNativeMessage(HOST_NAME, message, (response) => {
      const error = chrome.runtime.lastError;
      if (error) {
        reject(new Error(error.message));
        return;
      }
      resolve(response);
    });
  });
}

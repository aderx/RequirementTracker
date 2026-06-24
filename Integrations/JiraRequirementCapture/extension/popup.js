const HOST_NAME = "com.aderx.requirementtracker.jira_capture";
const DEFAULT_DELAY_SECONDS = 5;
const SUCCESS_DELAY_SECONDS = 2;
const FALLBACK_SETTINGS = {
  jiraBaseURL: "http://jira.zstack.io/browse/",
  mrHosts: ["gitlab.zstack.io"]
};

const elements = {
  titleText: document.getElementById("titleText"),
  statusText: document.getElementById("statusText"),
  iconFrame: document.getElementById("iconFrame"),
  statusIcon: document.getElementById("statusIcon"),
  noticePanel: document.getElementById("noticePanel"),
  noticeText: document.getElementById("noticeText"),
  summaryPanel: document.getElementById("summaryPanel"),
  primaryLabel: document.getElementById("primaryLabel"),
  primaryValue: document.getElementById("primaryValue"),
  secondaryRow: document.getElementById("secondaryRow"),
  secondaryLabel: document.getElementById("secondaryLabel"),
  secondaryValue: document.getElementById("secondaryValue"),
  tertiaryRow: document.getElementById("tertiaryRow"),
  tertiaryLabel: document.getElementById("tertiaryLabel"),
  tertiaryValue: document.getElementById("tertiaryValue"),
  manualPanel: document.getElementById("manualPanel"),
  manualJiraInput: document.getElementById("manualJiraInput"),
  actions: document.getElementById("actions"),
  countdownText: document.getElementById("countdownText")
};

let currentSettings = FALLBACK_SETTINGS;
let timers = [];
let countdownButton = null;
let countdownBaseLabel = "";

document.addEventListener("DOMContentLoaded", run);

async function run() {
  clearTimers();
  resetContent();
  setView({
    tone: "blue",
    icon: "✓",
    title: "需求记录",
    message: "正在识别当前页面..."
  });

  const settingsResult = await loadPluginSettings();
  currentSettings = settingsResult.settings;

  try {
    const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
    if (!tab?.id) {
      throw new Error("没有找到当前标签页");
    }

    await chrome.scripting.executeScript({
      target: { tabId: tab.id },
      files: ["content.js"]
    });

    const response = await chrome.tabs.sendMessage(tab.id, {
      type: "EXTRACT_REQUIREMENT_PAGE",
      settings: currentSettings
    });

    if (!response?.ok) {
      throw new Error(response?.error || "页面没有返回识别结果");
    }

    await handlePageResult(response.result, settingsResult.hostError);
  } catch (error) {
    showUnsupported(error.message || "页面识别失败");
  }
}

async function handlePageResult(result, hostError) {
  if (!result || result.pageType === "unsupported") {
    showUnsupported(result?.reason || "当前页面暂不支持");
    return;
  }

  if (hostError) {
    showNativeHostError();
    return;
  }

  if (result.pageType === "jira") {
    await handleJiraPage(result.payload);
    return;
  }

  if (result.pageType === "mr") {
    await handleMRPage(result.payload);
    return;
  }

  showUnsupported("当前页面暂不支持");
}

async function handleJiraPage(payload) {
  hideManualInput();
  hideNotice();
  renderSummary("JIRA", payload.issueKey || payload.jiraKey || "未识别", "标题", payload.title || "暂无标题");
  setView({
    tone: "blue",
    icon: "✓",
    title: "正在检查 Jira...",
    message: "请稍等"
  });
  setActions([]);

  const inspect = await sendNativeMessage({
    type: "inspectRequirement",
    payload
  });

  if (!inspect?.ok) {
    throw new Error(inspect?.error || "查询 Jira 失败");
  }

  if (inspect.exists) {
    setView({
      tone: "subtle",
      icon: "=",
      title: "这个 Jira 已记录",
      message: "可以更新页面信息，也可以忽略本次添加"
    });
    renderSummary("JIRA", payload.issueKey || payload.jiraKey || "未识别", "标题", payload.title || "暂无标题");

    const ignoreButton = button("忽略", "primary-button", closePopup);
    const updateButton = button("更新", "secondary-button", () => saveJira(payload));
    const startButton = button("确认并开始开发", "start-button", () => saveJira(payload, { startDevelopment: true }));
    setActions([ignoreButton, updateButton, startButton]);
    scheduleDefault(DEFAULT_DELAY_SECONDS, ignoreButton, "忽略", closePopup);
    return;
  }

  setView({
    tone: "blue",
    icon: "✓",
    title: "添加这个 Jira？",
    message: "已从当前页面识别到需求信息"
  });
  renderSummary("JIRA", payload.issueKey || payload.jiraKey || "未识别", "标题", payload.title || "暂无标题");

  const cancelButton = button("取消", "secondary-button", closePopup);
  const addButton = button("添加", "primary-button", () => saveJira(payload));
  const startButton = button("确认并开始开发", "start-button", () => saveJira(payload, { startDevelopment: true }));
  setActions([cancelButton, addButton, startButton]);
  scheduleDefault(DEFAULT_DELAY_SECONDS, addButton, "添加", () => saveJira(payload));
}

async function saveJira(payload, { startDevelopment = false } = {}) {
  clearTimers();
  hideManualInput();
  setActions([]);
  setView({
    tone: "blue",
    icon: "✓",
    title: startDevelopment ? "正在保存并开始开发..." : "正在保存 Jira...",
    message: "请稍等"
  });

  const response = await sendNativeMessage({
    type: "upsertJiraRequirement",
    payload: { ...payload, startDevelopment }
  });

  if (!response?.ok) {
    throw new Error(response?.error || "保存 Jira 失败");
  }

  requestBadgeRefresh();

  let actionText;
  if (response.action === "created") {
    actionText = startDevelopment ? "Jira 已添加并转为开发中" : "Jira 已添加到 App";
  } else if (response.started) {
    actionText = "Jira 已更新并转为开发中";
  } else {
    actionText = "Jira 信息已更新到 App";
  }
  showSuccess("已保存", actionText);
}

async function handleMRPage(payload) {
  hideSummary();
  hideNotice();

  if (!payload.jiraURL && !payload.issueKey) {
    showManualJiraInput(payload);
    return;
  }

  await attachMRWithInspection(payload);
}

async function attachMRWithInspection(payload, replaceExisting = false) {
  clearTimers();
  hideManualInput();
  hideNotice();
  setActions([]);
  setView({
    tone: "blue",
    icon: "✓",
    title: "正在检查 Jira 记录...",
    message: "请稍等"
  });

  const target = jiraPayloadFromValue(payload.jiraURL || payload.issueKey || "");
  if (!target.issueKey) {
    showManualJiraInput(payload, "请输入完整 Jira 地址或 Jira 编号");
    return;
  }

  const inspect = await sendNativeMessage({
    type: "inspectRequirement",
    payload: target
  });

  if (!inspect?.ok) {
    throw new Error(inspect?.error || "查询 Jira 失败");
  }

  const existingMR = normalizedURL(inspect.mrURL || "");
  const newMR = normalizedURL(payload.mrURL || "");
  if (existingMR && existingMR !== newMR && !replaceExisting) {
    setView({
      tone: "subtle",
      icon: "◇",
      title: "替换已有 MR？",
      message: "这个 Jira 已经保存过 MR 地址"
    });
    renderSummary("JIRA", target.issueKey, "当前", displayURL(existingMR), "新 MR", displayURL(newMR));

    const ignoreButton = button("忽略", "primary-button", closePopup);
    const replaceButton = button("替换", "secondary-button", () => attachMRWithInspection(payload, true));
    setActions([ignoreButton, replaceButton]);
    scheduleDefault(DEFAULT_DELAY_SECONDS, ignoreButton, "忽略", closePopup);
    return;
  }

  if (existingMR === newMR) {
    showSuccess("已保存", "这个 MR 已经记录在对应 Jira 中");
    return;
  }

  await attachMR({
    issueKey: target.issueKey,
    jiraURL: target.jiraURL,
    mrURL: newMR,
    replaceExisting
  });
}

async function attachMR(payload) {
  clearTimers();
  hideManualInput();
  hideSummary();
  hideNotice();
  setActions([]);
  setView({
    tone: "blue",
    icon: "✓",
    title: "正在保存 MR...",
    message: "请稍等"
  });

  const response = await sendNativeMessage({
    type: "attachMergeRequest",
    payload
  });

  if (!response?.ok) {
    throw new Error(response?.error || "保存 MR 失败");
  }

  requestBadgeRefresh();

  const actionText = {
    created: "Jira 已新增，MR 已保存",
    attached: "MR 已保存到对应 Jira",
    replaced: "MR 地址已替换"
  }[response.action] || "需求记录已更新到 App";

  showSuccess("已保存", actionText);
}

function showManualJiraInput(payload, message = "输入完整 Jira 地址或 Jira 编号") {
  clearTimers();
  hideSummary();
  hideNotice();
  setView({
    tone: "blue",
    icon: "+",
    title: "需要关联 Jira",
    message
  });
  elements.manualPanel.classList.remove("hidden");
  elements.manualJiraInput.value = "";
  elements.manualJiraInput.focus();

  const cancelButton = button("取消", "secondary-button", closePopup);
  const saveButton = button("保存", "primary-button", async () => {
    const target = jiraPayloadFromValue(elements.manualJiraInput.value);
    if (!target.issueKey) {
      setStatus("请输入有效的 Jira 地址或编号", "error");
      return;
    }

    await attachMRWithInspection({
      ...payload,
      issueKey: target.issueKey,
      jiraURL: target.jiraURL
    });
  });
  setActions([cancelButton, saveButton]);
}

function showUnsupported() {
  hideSummary();
  hideManualInput();
  hideNotice();
  setView({
    tone: "warning",
    icon: "!",
    title: "暂不支持此页面",
    message: "请打开 Jira 详情页或 GitLab MR 页面"
  });

  const closeButton = button("关闭", "text-button muted", closePopup);
  setActions([closeButton]);
  scheduleClose(DEFAULT_DELAY_SECONDS, closeButton);
}

function showNativeHostError() {
  hideSummary();
  hideManualInput();
  setView({
    tone: "error",
    icon: "x",
    title: "Native Host 未连接",
    message: "请在 App 的插件配置里安装后重试"
  });
  showNotice("未找到本机通信组件，插件暂时不能写入 App");

  const closeButton = button("关闭", "text-button", closePopup);
  setActions([closeButton]);
  scheduleClose(DEFAULT_DELAY_SECONDS, closeButton);
}

function showSuccess(title, message) {
  hideSummary();
  hideManualInput();
  hideNotice();
  setView({
    tone: "success",
    icon: "✓",
    title,
    message
  });

  const closeButton = button("关闭", "text-button", closePopup);
  setActions([closeButton]);
  scheduleClose(SUCCESS_DELAY_SECONDS, closeButton);
}

function showOperationError(message) {
  hideManualInput();
  hideSummary();
  setView({
    tone: "error",
    icon: "x",
    title: "操作失败",
    message: "请检查插件配置后重试"
  });
  showNotice(message || "操作失败");

  const closeButton = button("关闭", "text-button", closePopup);
  setActions([closeButton]);
  scheduleClose(DEFAULT_DELAY_SECONDS, closeButton);
}

async function loadPluginSettings() {
  try {
    const response = await sendNativeMessage({ type: "getPluginSettings", payload: {} });
    if (!response?.ok) {
      throw new Error(response?.error || "读取插件配置失败");
    }

    return {
      settings: {
        ...FALLBACK_SETTINGS,
        ...(response.settings || {})
      },
      hostError: ""
    };
  } catch (error) {
    return {
      settings: FALLBACK_SETTINGS,
      hostError: error.message || "Native Host 未连接"
    };
  }
}

function jiraPayloadFromValue(value) {
  const raw = String(value || "").trim();
  const issueKey = jiraKeyFromText(raw);
  if (!issueKey) {
    return { issueKey: "", jiraURL: "" };
  }

  if (/^https?:\/\//i.test(raw)) {
    return {
      issueKey,
      jiraURL: normalizedURL(raw)
    };
  }

  return {
    issueKey,
    jiraURL: `${ensureTrailingSlash(currentSettings.jiraBaseURL || FALLBACK_SETTINGS.jiraBaseURL)}${issueKey}`
  };
}

function resetContent() {
  hideSummary();
  hideManualInput();
  hideNotice();
  setActions([]);
}

function setView({ tone, icon, title, message }) {
  elements.iconFrame.className = `icon-frame ${tone || "blue"}`;
  elements.statusIcon.className = icon.length > 1 ? "icon-symbol compact" : "icon-symbol";
  elements.statusIcon.textContent = icon;
  elements.titleText.textContent = title;
  setStatus(message || "");
}

function renderSummary(
  primaryLabel,
  primaryValue,
  secondaryLabel = "",
  secondaryValue = "",
  tertiaryLabel = "",
  tertiaryValue = ""
) {
  elements.summaryPanel.classList.remove("hidden");
  elements.primaryLabel.textContent = primaryLabel;
  elements.primaryValue.textContent = primaryValue || "-";
  setOptionalRow(elements.secondaryRow, elements.secondaryLabel, elements.secondaryValue, secondaryLabel, secondaryValue);
  setOptionalRow(elements.tertiaryRow, elements.tertiaryLabel, elements.tertiaryValue, tertiaryLabel, tertiaryValue);
}

function setOptionalRow(row, labelElement, valueElement, label, value) {
  if (label || value) {
    row.classList.remove("hidden");
    labelElement.textContent = label;
    valueElement.textContent = value || "-";
    return;
  }

  row.classList.add("hidden");
}

function hideSummary() {
  elements.summaryPanel.classList.add("hidden");
  elements.secondaryRow.classList.add("hidden");
  elements.tertiaryRow.classList.add("hidden");
}

function showNotice(text) {
  elements.noticePanel.classList.remove("hidden");
  elements.noticeText.textContent = text;
}

function hideNotice() {
  elements.noticePanel.classList.add("hidden");
  elements.noticeText.textContent = "";
}

function hideManualInput() {
  elements.manualPanel.classList.add("hidden");
}

function setActions(actions) {
  elements.actions.innerHTML = "";
  if (Array.isArray(elements.actions.children)) {
    elements.actions.children.length = 0;
  }
  elements.actions.classList.toggle("hidden", actions.length === 0);
  elements.actions.classList.toggle("single", actions.length === 1);
  elements.actions.classList.toggle("triple", actions.length === 3);
  actions.forEach((action) => elements.actions.appendChild(action));
}

function requestBadgeRefresh() {
  try {
    chrome.runtime?.sendMessage?.({ type: "REFRESH_ACTIVE_TAB_BADGE" });
  } catch {
    // 后台不可用时忽略，标记会在下次切换标签页时刷新
  }
}

function button(label, className, onClick) {
  const element = document.createElement("button");
  element.type = "button";
  element.className = className;
  element.textContent = label;
  element.__baseLabel = label;
  element.addEventListener("click", async () => {
    clearTimers();
    element.disabled = true;
    try {
      await onClick();
    } catch (error) {
      showOperationError(error.message || "操作失败");
    }
  });
  return element;
}

function scheduleDefault(seconds, actionButton, actionLabel, action) {
  clearTimers();
  countdownButton = actionButton;
  countdownBaseLabel = actionLabel;

  let remaining = seconds;
  updateCountdownButton(remaining);
  const intervalID = setInterval(() => {
    remaining -= 1;
    if (remaining > 0) {
      updateCountdownButton(remaining);
    }
  }, 1000);
  const timeoutID = setTimeout(async () => {
    clearTimers();
    try {
      await action();
    } catch (error) {
      showOperationError(error.message || "操作失败");
    }
  }, seconds * 1000);
  timers.push(intervalID, timeoutID);
}

function scheduleClose(seconds, actionButton) {
  scheduleDefault(seconds, actionButton, actionButton.__baseLabel || "关闭", closePopup);
}

function updateCountdownButton(remaining) {
  if (!countdownButton) {
    return;
  }

  countdownButton.textContent = `${countdownBaseLabel}（${remaining}s）`;
  elements.countdownText.textContent = "";
}

function clearTimers() {
  timers.forEach((timer) => {
    clearTimeout(timer);
    clearInterval(timer);
  });
  timers = [];
  if (countdownButton && countdownBaseLabel) {
    countdownButton.textContent = countdownBaseLabel;
  }
  countdownButton = null;
  countdownBaseLabel = "";
  elements.countdownText.textContent = "";
}

function closePopup() {
  window.close();
}

function setStatus(text, kind = "") {
  elements.statusText.textContent = text;
  elements.statusText.classList.toggle("success", kind === "success");
  elements.statusText.classList.toggle("error", kind === "error");
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

function normalizedURL(value) {
  try {
    const url = new URL(String(value || "").trim());
    url.search = "";
    url.hash = "";
    return url.toString().replace(/\/$/, (match) => (url.pathname === "/" ? match : ""));
  } catch {
    return String(value || "").trim();
  }
}

function displayURL(value) {
  const normalized = String(value || "").replace(/^https?:\/\//i, "");
  if (normalized.length <= 52) {
    return normalized;
  }

  return `${normalized.slice(0, 29)}...${normalized.slice(-20)}`;
}

function jiraKeyFromText(value) {
  return String(value || "").match(/\b[A-Z][A-Z0-9]+-\d+\b/i)?.[0]?.toUpperCase() || "";
}

function ensureTrailingSlash(value) {
  const normalized = normalizedURL(value || FALLBACK_SETTINGS.jiraBaseURL);
  return normalized.endsWith("/") ? normalized : `${normalized}/`;
}

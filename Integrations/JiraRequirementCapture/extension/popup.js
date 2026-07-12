const HOST_NAME = "com.aderx.requirementtracker.jira_capture";
const REQUIRED_NATIVE_HOST_PROTOCOL_VERSION = 2;
const DEFAULT_DELAY_SECONDS = 5;
const FALLBACK_SETTINGS = {
  jiraBaseURL: "http://jira.zstack.io/browse/",
  mrHosts: ["gitlab.zstack.io"]
};

// 需求状态推进链与展示名称，与 App 内保持一致。
const STATUS_FLOW = ["pending", "active", "done", "tested", "merged"];
const STATUS_NAMES = {
  pending: "待开发",
  active: "开发中",
  done: "开发完成",
  tested: "已自测",
  merged: "已合并",
  paused: "已暂停",
  stopped: "已停止"
};
const MR_STATE_NAMES = {
  open: "开启中",
  merged: "已合并",
  closed: "已关闭"
};

const elements = {
  titleText: document.getElementById("titleText"),
  statusText: document.getElementById("statusText"),
  iconFrame: document.getElementById("iconFrame"),
  statusIcon: document.getElementById("statusIcon"),
  summaryPanel: document.getElementById("summaryPanel"),
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

  let result;
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
      throw new Error(response?.error || "页面识别失败");
    }

    result = response.result;
  } catch {
    // 无法注入或读取页面（如浏览器内置页面），按不支持处理。
    showUnsupported();
    return;
  }

  try {
    await handlePageResult(result, settingsResult.hostError);
  } catch (error) {
    showOperationError(error.message || "操作失败");
  }
}

async function handlePageResult(result, hostError) {
  if (!result || result.pageType === "unsupported") {
    showUnsupported(result?.reason || "");
    return;
  }

  if (hostError) {
    showNativeHostError(hostError);
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

  showUnsupported();
}

async function handleJiraPage(payload) {
  hideManualInput();
  const issueKey = payload.issueKey || payload.jiraKey || "未识别";
  const title = payload.title || "暂无标题";
  const jiraURL = payload.jiraURL || jiraPayloadFromValue(issueKey).jiraURL;
  renderSummary([
    { label: "需求", value: issueKey, copyText: jiraURL },
    { label: "标题", value: title }
  ]);
  setView({
    tone: "blue",
    icon: "✓",
    title: "正在检查记录...",
    message: ""
  });
  setActions([]);

  const inspect = await sendNativeMessage({
    type: "inspectRequirement",
    payload
  });

  if (!inspect?.ok) {
    throw new Error(inspect?.error || "查询需求记录失败");
  }

  if (inspect.exists) {
    const next = jiraNextStatus(inspect.status);
    renderSummary([
      { label: "需求", value: issueKey, copyText: inspect.jiraURL || jiraURL },
      { label: "标题", value: title },
      { label: "记录状态", value: statusName(inspect.status) || "未知" }
    ]);
    setView({
      tone: "subtle",
      icon: "=",
      title: "需求已记录",
      message: ""
    });

    const actions = [
      button("更新信息", "secondary-button", () => saveJira(payload))
    ];
    if (next) {
      actions.push(button(`转为${statusName(next)}`, "start-button", () => saveJira(payload, { targetStatus: next })));
    }
    setActions(actions);
    return;
  }

  setView({
    tone: "blue",
    icon: "+",
    title: "添加这个需求？",
    message: ""
  });

  setActions([
    button("添加", "primary-button", () => saveJira(payload)),
    button("添加并开始开发", "start-button", () => saveJira(payload, { targetStatus: "active" }))
  ]);
}

async function saveJira(payload, { targetStatus = "" } = {}) {
  clearTimers();
  hideManualInput();
  setActions([]);
  setView({
    tone: "blue",
    icon: "✓",
    title: "正在保存...",
    message: ""
  });

  const response = await sendNativeMessage({
    type: "upsertJiraRequirement",
    payload: { ...payload, targetStatus }
  });

  if (!response?.ok) {
    throw new Error(response?.error || "保存失败");
  }

  requestBadgeRefresh();

  let actionText;
  if (response.action === "created") {
    actionText = response.statusUpdated
      ? `已添加，${statusSuccessText(response.targetStatus || targetStatus)}`
      : "已添加到需求记录";
  } else if (response.statusUpdated) {
    actionText = statusSuccessText(response.targetStatus || targetStatus);
  } else {
    actionText = "页面信息已更新";
  }
  showSuccess("完成", actionText);
}

async function handleMRPage(payload) {
  hideSummary();

  if (!payload.jiraURL && !payload.issueKey) {
    showManualJiraInput(payload);
    return;
  }

  await attachMRWithInspection(payload);
}

async function attachMRWithInspection(payload) {
  clearTimers();
  hideManualInput();
  setActions([]);
  setView({
    tone: "blue",
    icon: "✓",
    title: "正在检查记录...",
    message: ""
  });

  const target = jiraPayloadFromValue(payload.jiraURL || payload.issueKey || "");
  if (!target.issueKey) {
    showManualJiraInput(payload, "没有识别到有效的 Jira 编号");
    return;
  }

  const inspect = await sendNativeMessage({
    type: "inspectRequirement",
    payload: target
  });

  if (!inspect?.ok) {
    throw new Error(inspect?.error || "查询需求记录失败");
  }

  const newMR = normalizedURL(payload.mrURL || "");
  const recordedMRs = [
    inspect.mrURL,
    ...(Array.isArray(inspect.mrHistory) ? inspect.mrHistory : [])
  ]
    .map(normalizedURL)
    .filter(Boolean);
  const isRecorded = recordedMRs.includes(newMR);
  const targetStatus = mrTargetStatus(payload.mrState);
  const willAdvance = inspect.exists
    ? statusRank(targetStatus) > statusRank(inspect.status)
    : Boolean(targetStatus);

  if (isRecorded && !willAdvance) {
    const isTerminalCompletion = payload.mrState === "merged" && inspect.status === "merged";
    renderSummary([
      { label: "需求", value: target.issueKey, copyText: inspect.jiraURL || target.jiraURL },
      { label: "MR 状态", value: mrStateName(payload.mrState) || "未知" },
      { label: "记录状态", value: statusName(inspect.status) || "未知" }
    ]);
    setView({
      tone: isTerminalCompletion ? "success" : "subtle",
      icon: isTerminalCompletion ? "✓" : "=",
      title: isTerminalCompletion ? "需求已完成" : "MR 已记录",
      message: isTerminalCompletion ? "MR 与需求均为已合并状态" : "没有需要同步的变化"
    });

    const closeButton = button("关闭", "text-button muted", closePopup);
    setActions([closeButton]);
    scheduleClose(DEFAULT_DELAY_SECONDS, closeButton);
    return;
  }

  renderSummary([
    { label: "需求", value: target.issueKey, copyText: inspect.jiraURL || target.jiraURL },
    { label: "MR 状态", value: mrStateName(payload.mrState) || "未知" },
    { label: "记录状态", value: statusName(inspect.status) || "未记录" }
  ]);
  setView({
    tone: "blue",
    icon: isRecorded ? "=" : "+",
    title: isRecorded ? "同步 MR 状态" : "关联 MR",
    message: ""
  });
  const requestedTargetStatus = willAdvance ? targetStatus : "";
  const actionLabel = requestedTargetStatus
    ? "转为" + statusName(requestedTargetStatus)
    : "保存 MR";
  setActions([
    button(actionLabel, "primary-button", () => attachMR({
      issueKey: target.issueKey,
      jiraURL: target.jiraURL,
      mrURL: newMR,
      mrState: payload.mrState,
      targetStatus: requestedTargetStatus
    }))
  ]);
}

async function attachMR(payload) {
  clearTimers();
  hideManualInput();
  hideSummary();
  setActions([]);
  setView({
    tone: "blue",
    icon: "✓",
    title: "正在保存 MR...",
    message: ""
  });

  const response = await sendNativeMessage({
    type: "attachMergeRequest",
    payload
  });

  if (!response?.ok) {
    throw new Error(response?.error || "保存 MR 失败");
  }

  requestBadgeRefresh();

  const issueKey = response.issueKey || payload.issueKey;
  const actionText = {
    created: `已创建 ${issueKey} 并保存 MR`,
    attached: `MR 已保存到 ${issueKey}`,
    appended: "新 MR 已保存",
    synced: "MR 状态已同步"
  }[response.action] || "需求记录已更新";

  showSuccess("完成", response.statusUpdated
    ? `${actionText}，${statusSuccessText(response.targetStatus)}`
    : actionText);
}

function showManualJiraInput(payload, message = "当前 MR 页面没有找到 Jira 链接") {
  clearTimers();
  hideSummary();
  setView({
    tone: "blue",
    icon: "+",
    title: "关联 Jira",
    message
  });
  elements.manualPanel.classList.remove("hidden");
  elements.manualJiraInput.value = "";
  elements.manualJiraInput.focus();

  const saveButton = button("保存", "primary-button", async () => {
    const target = jiraPayloadFromValue(elements.manualJiraInput.value);
    if (!target.issueKey) {
      setStatus("请输入 Jira 编号或完整链接", "error");
      return;
    }

    await attachMRWithInspection({
      ...payload,
      issueKey: target.issueKey,
      jiraURL: target.jiraURL
    });
  });
  setActions([saveButton]);
}

function showUnsupported(message = "") {
  hideSummary();
  hideManualInput();
  setView({
    tone: "warning",
    icon: "!",
    title: "此页面暂不支持",
    message: message || "支持 Jira 详情页和 GitLab MR 页面"
  });

  const closeButton = button("关闭", "text-button muted", closePopup);
  setActions([closeButton]);
  scheduleClose(DEFAULT_DELAY_SECONDS, closeButton);
}

function showNativeHostError(message = "") {
  hideSummary();
  hideManualInput();
  setView({
    tone: "error",
    icon: "x",
    title: "未连接到 App",
    message: message || "请先打开需求记录 App，并在设置的插件配置中安装 Native Host"
  });

  const closeButton = button("关闭", "text-button", closePopup);
  setActions([closeButton]);
}

function showSuccess(title, message) {
  hideSummary();
  hideManualInput();
  setView({
    tone: "success",
    icon: "✓",
    title,
    message
  });

  const closeButton = button("关闭", "text-button", closePopup);
  setActions([closeButton]);
  scheduleClose(DEFAULT_DELAY_SECONDS, closeButton);
}

function showOperationError(message) {
  hideManualInput();
  hideSummary();
  setView({
    tone: "error",
    icon: "x",
    title: "操作失败",
    message: message || "请稍后重试"
  });

  const closeButton = button("关闭", "text-button", closePopup);
  setActions([closeButton]);
}

async function loadPluginSettings() {
  try {
    const response = await sendNativeMessage({ type: "getPluginSettings", payload: {} });
    if (!response?.ok) {
      throw new Error(response?.error || "读取插件配置失败");
    }
    const protocolVersion = Number(response.protocolVersion || 0);
    if (protocolVersion < REQUIRED_NATIVE_HOST_PROTOCOL_VERSION) {
      throw new Error("Native Host 版本过旧，请在 App 设置中重新安装");
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

function statusName(status) {
  return STATUS_NAMES[String(status || "").toLowerCase()] || "";
}

function statusRank(status) {
  return STATUS_FLOW.indexOf(String(status || "").toLowerCase());
}

function jiraNextStatus(status) {
  switch (String(status || "").toLowerCase()) {
  case "pending":
    return "active";
  case "active":
    return "done";
  default:
    return "";
  }
}

function mrTargetStatus(state) {
  switch (String(state || "").toLowerCase()) {
  case "open":
    return "tested";
  case "merged":
    return "merged";
  default:
    return "";
  }
}

function mrStateName(state) {
  return MR_STATE_NAMES[String(state || "").toLowerCase()] || "";
}

function statusSuccessText(status) {
  const name = statusName(status);
  return name ? `需求已转为${name}` : "需求状态已更新";
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
  setActions([]);
}

function setView({ tone, icon, title, message }) {
  elements.iconFrame.className = `icon-frame ${tone || "blue"}`;
  elements.statusIcon.className = icon.length > 1 ? "icon-symbol compact" : "icon-symbol";
  elements.statusIcon.textContent = icon;
  elements.titleText.textContent = title;
  setStatus(message || "");
}

function renderSummary(rows) {
  const visibleRows = (rows || []).filter((row) => row && (row.label || row.value));
  elements.summaryPanel.innerHTML = "";
  if (Array.isArray(elements.summaryPanel.children)) {
    elements.summaryPanel.children.length = 0;
  }
  elements.summaryPanel.classList.toggle("hidden", visibleRows.length === 0);

  for (const row of visibleRows) {
    const rowElement = document.createElement("div");
    rowElement.className = "row";

    const label = document.createElement("span");
    label.className = "label";
    label.textContent = row.label;
    rowElement.appendChild(label);

    const value = document.createElement("span");
    value.className = "value";
    value.textContent = row.value || "-";
    if (row.copyText) {
      value.appendChild(copyButtonFor(row.copyText));
    }
    rowElement.appendChild(value);

    elements.summaryPanel.appendChild(rowElement);
  }
}

/// 复制按钮：点击后把 text 写入剪贴板，并给出短暂的“已复制”反馈。
function copyButtonFor(text) {
  const element = document.createElement("button");
  element.type = "button";
  element.className = "copy-button";
  element.textContent = "复制";
  element.title = text;
  element.addEventListener("click", async () => {
    try {
      await navigator.clipboard.writeText(text);
      element.textContent = "已复制";
      element.classList.add("copied");
    } catch {
      element.textContent = "复制失败";
    }
    setTimeout(() => {
      element.textContent = "复制";
      element.classList.remove("copied");
    }, 1500);
  });
  return element;
}

function hideSummary() {
  elements.summaryPanel.classList.add("hidden");
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
    } finally {
      element.disabled = false;
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

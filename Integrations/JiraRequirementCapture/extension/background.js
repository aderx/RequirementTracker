// 后台 Service Worker：根据当前标签页地址在插件图标上显示原生矩形角标。
// 图标本身是蓝色的，角标用高对比颜色区分状态：
// - 不支持的页面：不显示角标
// - 可添加（支持的 Jira / MR 页面但尚未记录）：橙色「+」
// - 已记录：绿色「↻」
// - 已完成的 Jira / MR 记录：绿色「✓」
const HOST_NAME = "com.aderx.requirementtracker.jira_capture";
const REQUIRED_NATIVE_HOST_PROTOCOL_VERSION = 2;
const FALLBACK_SETTINGS = {
  jiraBaseURL: "http://jira.zstack.io/browse/",
  mrHosts: ["gitlab.zstack.io"]
};
const SETTINGS_TTL_MS = 5 * 60 * 1000;

const BADGE_STYLES = {
  addable: { text: "+", color: "#FF9500" },
  recorded: { text: "↻", color: "#1F9D54" },
  completed: { text: "✓", color: "#1F9D54" }
};

let cachedSettings = null;
let cachedSettingsAt = 0;
let cachedHostCompatible = false;

chrome.runtime.onInstalled.addListener(refreshActiveTab);
chrome.runtime.onStartup.addListener(refreshActiveTab);

chrome.tabs.onActivated.addListener(({ tabId }) => {
  chrome.tabs.get(tabId, (tab) => {
    if (chrome.runtime.lastError || !tab) {
      return;
    }
    updateBadgeForTab(tab.id, tab.url || "");
  });
});

chrome.tabs.onUpdated.addListener((tabId, changeInfo, tab) => {
  // 导航会重置标签页级图标，loading 阶段就重画一次，避免角标长时间缺失。
  if (changeInfo.status === "loading" || changeInfo.status === "complete" || typeof changeInfo.url === "string") {
    updateBadgeForTab(tabId, tab.url || "");
  }
});

chrome.runtime.onMessage.addListener((message) => {
  if (message?.type === "REFRESH_ACTIVE_TAB_BADGE") {
    cachedSettings = null;
    refreshActiveTab();
  }
  return false;
});

function refreshActiveTab() {
  chrome.tabs.query({ active: true, lastFocusedWindow: true }, (tabs) => {
    const tab = tabs && tabs[0];
    if (tab && tab.id != null) {
      updateBadgeForTab(tab.id, tab.url || "");
    }
  });
}

async function updateBadgeForTab(tabId, url) {
  try {
    applyBadge(tabId, await resolveState(url));
  } catch {
    applyBadge(tabId, "unsupported");
  }
}

async function resolveState(url) {
  const pageType = await detectPageType(url);
  if (pageType === "unsupported") {
    return "unsupported";
  }
  if (!cachedHostCompatible) {
    return "unsupported";
  }

  try {
    const response = await sendNativeMessage({
      type: "inspectByURL",
      payload: { url: canonicalPageURL(url) }
    });
    if (response?.ok && response.exists) {
      if (response.status === "merged") {
        return "completed";
      }
      return "recorded";
    }
  } catch {
    // Native Host 不可用时，支持的页面仍按“可添加”展示。
  }

  return "addable";
}

// MR 的“变更/提交/流水线”等子页统一归到 MR 主地址，与记录的 mrURL 匹配。
function canonicalPageURL(value) {
  return normalizedURL(value).replace(/(\/-\/merge_requests\/\d+)\/[a-z_]+$/i, "$1");
}

async function detectPageType(url) {
  const normalized = normalizedURL(url);
  let parsed;
  try {
    parsed = new URL(normalized);
  } catch {
    return "unsupported";
  }

  if (!/^https?:$/i.test(parsed.protocol)) {
    return "unsupported";
  }

  const settings = await loadSettings();
  const host = parsed.hostname.toLowerCase();
  const jiraHost = hostFromURL(settings.jiraBaseURL);

  if (isJiraDetailURL(normalized) && (!jiraHost || host === jiraHost)) {
    return "jira";
  }

  const mrHosts = (Array.isArray(settings.mrHosts) ? settings.mrHosts : [])
    .map((value) => String(value || "").toLowerCase());
  // 允许 MR 的 diffs/commits/pipelines 等子页，避免切换 Tab 后角标消失。
  if (mrHosts.includes(host) && /\/-\/merge_requests\/\d+(?:\/[a-z_]+)?\/?$/i.test(parsed.pathname)) {
    return "mr";
  }

  return "unsupported";
}

function isJiraDetailURL(value) {
  return /\/browse\/[A-Z][A-Z0-9]+-\d+(?:\/)?$/i.test(String(value || ""));
}

async function loadSettings() {
  const now = Date.now();
  if (cachedSettings && now - cachedSettingsAt < SETTINGS_TTL_MS) {
    return cachedSettings;
  }

  try {
    const response = await sendNativeMessage({ type: "getPluginSettings", payload: {} });
    if (response?.ok) {
      cachedHostCompatible = Number(response.protocolVersion || 0) >= REQUIRED_NATIVE_HOST_PROTOCOL_VERSION;
      cachedSettings = { ...FALLBACK_SETTINGS, ...(response.settings || {}) };
      cachedSettingsAt = now;
      return cachedSettings;
    }
  } catch {
    // 忽略，用回退配置。
  }

  cachedHostCompatible = false;
  cachedSettings = cachedSettings || FALLBACK_SETTINGS;
  cachedSettingsAt = now;
  return cachedSettings;
}

function applyBadge(tabId, state) {
  const style = BADGE_STYLES[state];
  chrome.action.setBadgeText({ tabId, text: style?.text || "" }, ignoreError);
  if (!style) {
    return;
  }

  chrome.action.setBadgeBackgroundColor({ tabId, color: style.color }, ignoreError);
  if (chrome.action.setBadgeTextColor) {
    chrome.action.setBadgeTextColor({ tabId, color: "#FFFFFF" }, ignoreError);
  }
}

function ignoreError() {
  void chrome.runtime.lastError;
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

function hostFromURL(value) {
  try {
    return new URL(String(value || "").trim()).hostname.toLowerCase();
  } catch {
    return "";
  }
}

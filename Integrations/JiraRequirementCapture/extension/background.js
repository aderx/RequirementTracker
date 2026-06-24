// 后台 Service Worker：根据当前标签页地址在插件图标右下角显示状态标记。
// - 已记录：绿色「✓」
// - 可记录（支持的 Jira / MR 页面但尚未记录）：蓝色「+」
// - 不支持处理的页面：灰色「–」
const HOST_NAME = "com.aderx.requirementtracker.jira_capture";
const FALLBACK_SETTINGS = {
  jiraBaseURL: "http://jira.zstack.io/browse/",
  mrHosts: ["gitlab.zstack.io"]
};
const SETTINGS_TTL_MS = 5 * 60 * 1000;

const BADGE = {
  recorded: { text: "✓", color: "#34C759" },
  addable: { text: "+", color: "#2F8CFF" },
  unsupported: { text: "–", color: "#9AA0A6" }
};

let cachedSettings = null;
let cachedSettingsAt = 0;

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
  if (changeInfo.status === "complete" || typeof changeInfo.url === "string") {
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

  try {
    const response = await sendNativeMessage({ type: "inspectByURL", payload: { url } });
    if (response?.ok && response.exists) {
      return "recorded";
    }
  } catch {
    // Native Host 不可用时，支持的页面仍按“可记录”展示。
  }

  return "addable";
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
  if (mrHosts.includes(host) && /\/-\/merge_requests\/\d+(?:\/)?$/i.test(parsed.pathname)) {
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
      cachedSettings = { ...FALLBACK_SETTINGS, ...(response.settings || {}) };
      cachedSettingsAt = now;
      return cachedSettings;
    }
  } catch {
    // 忽略，用回退配置。
  }

  cachedSettings = cachedSettings || FALLBACK_SETTINGS;
  cachedSettingsAt = now;
  return cachedSettings;
}

function applyBadge(tabId, state) {
  const config = BADGE[state] || BADGE.unsupported;
  chrome.action.setBadgeText({ tabId, text: config.text }, ignoreError);
  chrome.action.setBadgeBackgroundColor({ tabId, color: config.color }, ignoreError);
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

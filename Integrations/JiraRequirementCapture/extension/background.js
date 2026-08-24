// 后台 Service Worker：根据当前标签页地址更新插件图标右下角的浏览器原生角标。
// 主图标始终保持蓝色，右下角的位置、溢出效果和字符排版交给 Chrome：
// - 不支持的页面：不显示角标
// - 可添加（支持的 Jira / MR 页面但尚未记录）：橙色「+」
// - 已记录：生产版绿色「↻」
// - 开发完成：蓝色「✓」
// - 已自测：紫色重勾「✔」
// - 已合并：绿色「⇧」
// - 已暂停：琥珀色「Ⅱ」
// - 已停止：红色「■」
importScripts("badge-renderer.js");

const HOST_NAME = "com.aderx.requirementtracker.jira_capture";
const REQUIRED_NATIVE_HOST_PROTOCOL_VERSION = 3;
const TEST_PAGE_PATH = "test.html";
const TEST_PAGE_CONTEXT_MENU_ID = "open-requirementtracker-status-test";
const MR_MONITOR_ALARM_NAME = "requirementtracker-mr-merge-monitor";
const MR_MONITOR_INTERVAL_MINUTES = 15;
const FALLBACK_SETTINGS = {
  jiraBaseURL: "http://jira.zstack.io/browse/",
  mrHosts: ["gitlab.zstack.io"]
};
const SETTINGS_TTL_MS = 5 * 60 * 1000;
const DEFAULT_ACTION_ICONS = {
  16: "icons/icon-16.png",
  32: "icons/icon-32.png",
  48: "icons/icon-48.png",
  128: "icons/icon-128.png"
};
const BADGE_STYLES = BadgeIconRenderer.styles;
const TESTABLE_STATES = new Set(["unsupported", ...Object.keys(BADGE_STYLES)]);

let cachedSettings = null;
let cachedSettingsAt = 0;
let cachedHostCompatible = false;

chrome.runtime.onInstalled.addListener(() => {
  installTestPageContextMenu();
  ensureMRMonitorAlarm();
  refreshActiveTab();
  checkMonitoredMRs();
});
chrome.runtime.onStartup.addListener(() => {
  installTestPageContextMenu();
  ensureMRMonitorAlarm();
  refreshActiveTab();
  checkMonitoredMRs();
});

chrome.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name === MR_MONITOR_ALARM_NAME) {
    checkMonitoredMRs();
  }
});

chrome.contextMenus.onClicked.addListener((info) => {
  if (info.menuItemId === TEST_PAGE_CONTEXT_MENU_ID) {
    chrome.tabs.create({ url: chrome.runtime.getURL(TEST_PAGE_PATH) });
  }
});

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

chrome.runtime.onMessage.addListener(handleRuntimeMessage);

function handleRuntimeMessage(message, sender, sendResponse) {
  if (message?.type === "REFRESH_ACTIVE_TAB_BADGE") {
    cachedSettings = null;
    refreshActiveTab();
    return false;
  }

  if (message?.type === "APPLY_TEST_PAGE_STATE") {
    const tabId = sender.tab?.id ?? message.tabId;
    const url = String(message.url || "");
    const requestedState = testStateFromURL(url);
    if (!Number.isInteger(tabId) || !requestedState) {
      sendResponse({ ok: false, error: "没有找到有效的插件测试页" });
      return false;
    }

    updateBadgeForTab(tabId, url)
      .then((appliedState) => sendResponse({ ok: true, state: appliedState }))
      .catch(() => sendResponse({ ok: false, error: "插件状态切换失败" }));
    return true;
  }

  return false;
}

function installTestPageContextMenu() {
  chrome.contextMenus.remove(TEST_PAGE_CONTEXT_MENU_ID, () => {
    void chrome.runtime.lastError;
    chrome.contextMenus.create({
      id: TEST_PAGE_CONTEXT_MENU_ID,
      title: "打开状态测试页",
      contexts: ["action"]
    }, ignoreError);
  });
}

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
    const state = await resolveState(url, tabId);
    await applyBadge(tabId, state);
    return state;
  } catch {
    await applyBadge(tabId, "unsupported");
    return "unsupported";
  }
}

async function resolveState(url, tabId) {
  const testState = testStateFromURL(url);
  if (testState) {
    return testState;
  }

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
      const status = String(response.status || "").toLowerCase();
      if (["done", "tested", "merged", "paused", "stopped"].includes(status)) {
        return status;
      }
      return "recorded";
    }
  } catch {
    // Native Host 不可用时，支持的页面仍按“可添加”展示。
  }

  const ownership = await readPageOwnership(tabId, pageType);
  return ownership === "other" ? "unsupported" : "addable";
}

async function readPageOwnership(tabId, pageType) {
  if (!Number.isInteger(tabId)) {
    return "unknown";
  }

  try {
    const response = await chrome.tabs.sendMessage(tabId, {
      type: "EXTRACT_PAGE_OWNERSHIP",
      pageType
    });
    const ownership = String(response?.ownership || "").toLowerCase();
    return ["mine", "other"].includes(ownership) ? ownership : "unknown";
  } catch {
    return "unknown";
  }
}

function ensureMRMonitorAlarm() {
  chrome.alarms.create(MR_MONITOR_ALARM_NAME, {
    periodInMinutes: MR_MONITOR_INTERVAL_MINUTES
  });
}

async function checkMonitoredMRs() {
  let response;
  try {
    response = await sendNativeMessage({
      type: "listMRMergeMonitors",
      payload: {}
    });
  } catch {
    return;
  }

  const monitors = Array.isArray(response?.monitors) ? response.monitors : [];
  for (const monitor of monitors) {
    const issueKey = String(monitor?.issueKey || "").trim();
    const mrURL = canonicalPageURL(monitor?.mrURL || "");
    if (!issueKey || !mrURL) {
      continue;
    }

    if (await fetchMRState(mrURL) !== "merged") {
      continue;
    }

    try {
      await sendNativeMessage({
        type: "markMRMergeMonitorMerged",
        payload: { issueKey, mrURL }
      });
    } catch {
      // 单个 MR 写回失败不影响其它监听项。
    }
  }
}

async function fetchMRState(mrURL) {
  const candidates = [`${mrURL}.json`, mrURL];
  for (const candidate of candidates) {
    try {
      const response = await fetch(candidate, {
        method: "GET",
        credentials: "include",
        cache: "no-store",
        redirect: "follow"
      });
      if (!response.ok) {
        continue;
      }

      const state = extractMRStateFromResponseText(await response.text());
      if (state) {
        return state;
      }
    } catch {
      // 登录失效、网络不可达或页面结构未知时保持原状态，等待下次检查。
    }
  }

  return "";
}

function extractMRStateFromResponseText(value) {
  const text = String(value || "");
  if (!text) {
    return "";
  }

  try {
    const payload = JSON.parse(text);
    const state = String(payload?.state || payload?.merge_request?.state || "").toLowerCase();
    if (["merged", "open", "closed"].includes(state)) {
      return state;
    }
  } catch {
    // HTML 响应继续使用 GitLab 服务端状态字段判断。
  }

  const normalized = text
    .replace(/&quot;|&#34;/gi, '"')
    .replace(/&#39;|&apos;/gi, "'");
  const statePatterns = [
    /data-(?:merge-request-)?state=["'](merged|open|closed)["']/i,
    /["']state["']\s*:\s*["'](merged|open|closed)["']/i,
    /["']merge_request_state["']\s*:\s*["'](merged|open|closed)["']/i
  ];
  for (const pattern of statePatterns) {
    const state = normalized.match(pattern)?.[1]?.toLowerCase();
    if (state) {
      return state;
    }
  }

  return "";
}

function testStateFromURL(value) {
  try {
    const testPageURL = new URL(chrome.runtime.getURL(TEST_PAGE_PATH));
    const pageURL = new URL(String(value || ""));
    if (pageURL.origin !== testPageURL.origin || pageURL.pathname !== testPageURL.pathname) {
      return "";
    }

    const state = pageURL.searchParams.get("state") || "unsupported";
    return TESTABLE_STATES.has(state) ? state : "unsupported";
  } catch {
    return "";
  }
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

async function applyBadge(tabId, state) {
  const style = BADGE_STYLES[state];
  chrome.action.setIcon({
    tabId,
    path: DEFAULT_ACTION_ICONS
  }, ignoreError);
  chrome.action.setBadgeText({ tabId, text: style?.text || "" }, ignoreError);

  if (!style) {
    chrome.action.setTitle({ tabId, title: "记录 Jira / MR" }, ignoreError);
    return;
  }

  chrome.action.setBadgeBackgroundColor({ tabId, color: style.color }, ignoreError);
  if (typeof chrome.action.setBadgeTextColor === "function") {
    chrome.action.setBadgeTextColor({ tabId, color: "#FFFFFF" }, ignoreError);
  }
  chrome.action.setTitle({ tabId, title: `需求记录：${style.label}` }, ignoreError);
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

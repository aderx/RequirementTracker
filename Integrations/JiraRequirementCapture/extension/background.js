// 普通页面保留原 Logo；需求状态使用完整的渐变图标，不叠加原生文字角标。
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
let supportsAutomaticMRStatus = false;
let automaticWriteQueue = Promise.resolve();
const tabSynchronizations = new Map();

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
  if (message?.type === "MR_PAGE_CHANGED" && Number.isInteger(sender.tab?.id)) {
    updateBadgeForTab(sender.tab.id, sender.tab.url || "")
      .then((state) => sendResponse({ ok: true, state }))
      .catch(() => sendResponse({ ok: false }));
    return true;
  }

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
    await synchronizeMRForTab(tabId, url);
    const state = await resolveState(url, tabId);
    await applyBadge(tabId, state);
    return state;
  } catch {
    await applyBadge(tabId, "unsupported");
    return "unsupported";
  }
}

// 后台、页面加载和局部更新共用入口；自动写入串行执行，重复事件不追加时间线。
function writeAutomaticStatus(payload) {
  const result = automaticWriteQueue.then(() => sendNativeMessage({ type: "syncMRStatus", payload }));
  automaticWriteQueue = result.catch(() => {});
  return result;
}

function synchronizeMRForTab(tabId, url) {
  const key = `${tabId}:${canonicalPageURL(url)}`;
  if (tabSynchronizations.has(key)) return tabSynchronizations.get(key);
  const task = synchronizeMRPage(tabId, url).catch(() => {}).finally(() => tabSynchronizations.delete(key));
  tabSynchronizations.set(key, task);
  return task;
}

async function synchronizeMRPage(tabId, url) {
  if (!Number.isInteger(tabId) || await detectPageType(url) !== "mr" || !supportsAutomaticMRStatus) return;
  const mrURL = canonicalPageURL(url);
  const response = await chrome.tabs.sendMessage(tabId, {
    type: "EXTRACT_AUTOMATIC_MR_CONTEXT", settings: await loadSettings()
  });
  const context = response?.ok && response.result;
  if (!context || canonicalPageURL(context.mrURL) !== mrURL) return;
  const binding = await sendNativeMessage({ type: "inspectByURL", payload: { mrURL } });
  if (!binding?.ok) return;
  const issueKeys = Array.isArray(context.issueKeys) ? [...new Set(context.issueKeys)] : [];
  if (!binding.exists && (context.ownership !== "mine" || issueKeys.length !== 1)) return;
  const issueKey = binding.exists ? binding.issueKey : issueKeys[0];
  if (!binding.exists) {
    const requirement = await sendNativeMessage({ type: "inspectRequirement", payload: { issueKey } });
    if (!requirement?.ok || !requirement.exists) return;
  }
  const mrState = context.mrState || await fetchMRState(mrURL, true);
  if (!["open", "merged"].includes(mrState)) return;
  // 异步识别期间可能已跳转到另一个 MR，旧页面结果不写回。
  const currentTab = await chrome.tabs.get(tabId);
  if (!currentTab?.url || canonicalPageURL(currentTab.url) !== mrURL) return;
  await writeAutomaticStatus({ mrURL, issueKey, mrState, allowInitialBinding: !binding.exists });
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

  const manualMonitors = Array.isArray(response?.monitors) ? response.monitors : [];
  await loadSettings();
  let automaticMonitors = [];
  if (supportsAutomaticMRStatus) {
    try {
      const automatic = await sendNativeMessage({ type: "listAutomaticMRMonitors", payload: {} });
      automaticMonitors = Array.isArray(automatic?.monitors) ? automatic.monitors : [];
    } catch { /* 旧版本 Host 不支持时保留原监听行为。 */ }
  }
  const automaticURLs = new Set(automaticMonitors.map(item => canonicalPageURL(item.mrURL)));
  const monitors = [...automaticMonitors, ...manualMonitors.filter(item => !automaticURLs.has(canonicalPageURL(item.mrURL)))];
  for (const monitor of monitors) {
    const issueKey = String(monitor?.issueKey || "").trim();
    const mrURL = canonicalPageURL(monitor?.mrURL || "");
    if (!issueKey || !mrURL || await detectPageType(mrURL) !== "mr") continue;
    if (await fetchMRState(mrURL, monitor.automatic === true) !== "merged") continue;
    try {
      if (monitor.automatic === true) {
        await writeAutomaticStatus({ issueKey, mrURL, mrState: "merged" });
      } else {
        await sendNativeMessage({ type: "markMRMergeMonitorMerged", payload: { issueKey, mrURL } });
      }
    } catch { /* 单个 MR 写回失败不影响其它监听项。 */ }
  }
  refreshActiveTab();
}

async function fetchMRState(mrURL, structuredOnly = false) {
  const candidates = structuredOnly ? [`${mrURL}.json`] : [`${mrURL}.json`, mrURL];
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

      const text = await response.text();
      let state;
      if (structuredOnly) {
        if (response.url && canonicalPageURL(response.url.replace(/\.json(?=[?#]|$)/, "")) !== mrURL) continue;
        const payload = JSON.parse(text);
        state = String(payload?.state || payload?.merge_request?.state || "").toLowerCase();
        if (state === "opened") state = "open";
        if (!["open", "merged", "closed"].includes(state)) continue;
      } else {
        state = extractMRStateFromResponseText(text);
      }
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
      supportsAutomaticMRStatus = cachedHostCompatible && response.supportsAutomaticMRStatus === true;
      cachedSettings = { ...FALLBACK_SETTINGS, ...(response.settings || {}) };
      cachedSettingsAt = now;
      return cachedSettings;
    }
  } catch {
    // 忽略，用回退配置。
  }

  cachedHostCompatible = false;
  supportsAutomaticMRStatus = false;
  cachedSettings = cachedSettings || FALLBACK_SETTINGS;
  cachedSettingsAt = now;
  return cachedSettings;
}

async function applyBadge(tabId, state) {
  const style = BADGE_STYLES[state];
  chrome.action.setIcon({
    tabId,
    path: style
      ? Object.fromEntries(Object.keys(DEFAULT_ACTION_ICONS).map((size) => [size, `icons/status/${state}-${size}.png`]))
      : DEFAULT_ACTION_ICONS
  }, ignoreError);
  chrome.action.setBadgeText({ tabId, text: "" }, ignoreError);

  if (!style) {
    chrome.action.setTitle({ tabId, title: "记录 Jira / MR" }, ignoreError);
    return;
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

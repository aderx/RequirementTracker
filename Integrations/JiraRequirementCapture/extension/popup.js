const HOST_NAME = "com.aderx.requirementtracker.jira_capture";

const elements = {
  statusText: document.getElementById("statusText"),
  extractButton: document.getElementById("extractButton"),
  saveButton: document.getElementById("saveButton"),
  copyButton: document.getElementById("copyButton"),
  issueKeyValue: document.getElementById("issueKeyValue"),
  titleValue: document.getElementById("titleValue"),
  typeValue: document.getElementById("typeValue"),
  priorityValue: document.getElementById("priorityValue"),
  targetVersionValue: document.getElementById("targetVersionValue"),
  jsonPreview: document.getElementById("jsonPreview"),
  hostStatus: document.getElementById("hostStatus")
};

let currentPayload = null;

document.addEventListener("DOMContentLoaded", () => {
  elements.extractButton.addEventListener("click", extractFromCurrentTab);
  elements.saveButton.addEventListener("click", saveCurrentPayload);
  elements.copyButton.addEventListener("click", copyCurrentPayload);

  extractFromCurrentTab();
});

async function extractFromCurrentTab() {
  setStatus("正在读取当前页面...");
  setPayload(null);

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
      type: "EXTRACT_JIRA_REQUIREMENT"
    });

    if (!response?.ok) {
      throw new Error(response?.error || "页面没有返回提取结果");
    }

    setPayload(response.payload);
    const missing = missingRequiredFields(response.payload);
    if (missing.length > 0) {
      setStatus(`已提取，缺少：${missing.join("、")}`);
      return;
    }

    setStatus("已提取当前 Jira 页面");
  } catch (error) {
    setStatus(error.message || "提取失败");
    setPayload(null);
  }
}

function setPayload(payload) {
  currentPayload = payload;
  renderText(elements.issueKeyValue, payload?.issueKey);
  renderText(elements.titleValue, payload?.title);
  renderText(elements.typeValue, payload?.type);
  renderText(elements.priorityValue, payload?.priority);
  renderText(elements.targetVersionValue, payload?.targetVersion);

  elements.jsonPreview.value = payload ? JSON.stringify(payload, null, 2) : "";
  elements.saveButton.disabled = !payload?.issueKey;
  elements.copyButton.disabled = !payload;
}

function renderText(element, value) {
  const normalized = normalizeValue(value);
  element.textContent = normalized || "未识别";
  element.classList.toggle("empty", !normalized);
}

async function saveCurrentPayload() {
  if (!currentPayload?.issueKey) {
    setStatus("没有可保存的需求号");
    return;
  }

  setStatus("正在写入本地 JSON...");
  elements.saveButton.disabled = true;

  try {
    const response = await sendNativeMessage({
      type: "upsertRequirement",
      payload: currentPayload
    });

    if (!response?.ok) {
      throw new Error(response?.error || "Native Host 写入失败");
    }

    const actionText = response.action === "created" ? "已新增" : "已更新";
    setStatus(`${actionText} ${currentPayload.issueKey}`);
    elements.hostStatus.textContent = response.dataFilePath || "已写入 app JSON";
  } catch (error) {
    setStatus(error.message || "写入失败");
    elements.hostStatus.textContent = "Native Host 写入失败";
  } finally {
    elements.saveButton.disabled = !currentPayload?.issueKey;
  }
}

async function copyCurrentPayload() {
  if (!currentPayload) {
    return;
  }

  await navigator.clipboard.writeText(JSON.stringify(currentPayload, null, 2));
  setStatus("已复制 JSON");
}

function missingRequiredFields(payload) {
  if (!payload) {
    return [];
  }

  const fields = [
    ["title", "标题"],
    ["type", "类型"],
    ["priority", "优先级"],
    ["targetVersion", "目标版本"]
  ];

  return fields
    .filter(([key]) => !normalizeValue(payload[key]))
    .map(([, label]) => label);
}

function normalizeValue(value) {
  return String(value ?? "").trim();
}

function setStatus(text) {
  elements.statusText.textContent = text;
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

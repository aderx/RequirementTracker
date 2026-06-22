(() => {
  if (window.__jiraRequirementCaptureInstalled) {
    return;
  }

  window.__jiraRequirementCaptureInstalled = true;

  chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
    if (message?.type !== "EXTRACT_JIRA_REQUIREMENT") {
      return false;
    }

    try {
      sendResponse({
        ok: true,
        payload: extractJiraRequirement()
      });
    } catch (error) {
      sendResponse({
        ok: false,
        error: error?.message || "Jira 字段提取失败"
      });
    }

    return true;
  });

  function extractJiraRequirement() {
    return compactPayload({
      issueKey: extractIssueKey(),
      title: extractTitle(),
      type: extractFieldValue({
        selectors: [
          "#type-val",
          "#issuetype-val",
          "[data-field-id='issuetype']",
          "[data-testid*='issue-type']"
        ],
        labels: ["类型", "Issue Type", "Type"]
      }),
      priority: extractFieldValue({
        selectors: [
          "#priority-val",
          "[data-field-id='priority']",
          "[data-testid*='priority']"
        ],
        labels: ["优先级", "Priority"]
      }),
      targetVersion: extractFieldValue({
        selectors: [
          "#fixVersions-field",
          "#fixVersions-val",
          "#fixfor-val",
          "[data-field-id='fixVersions']",
          "[data-testid*='fix-version']",
          "[data-testid*='fixversions']"
        ],
        labels: ["修复的版本", "目标版本", "Fix Version/s", "Fix Version", "Target Version"]
      }),
      url: location.href,
      capturedAt: new Date().toISOString()
    });
  }

  function extractIssueKey() {
    const fromURL = location.href.match(/\/browse\/([A-Z][A-Z0-9]+-\d+)/i)?.[1];
    if (fromURL) {
      return fromURL.toUpperCase();
    }

    const fromTitle = document.title.match(/\b[A-Z][A-Z0-9]+-\d+\b/i)?.[0];
    if (fromTitle) {
      return fromTitle.toUpperCase();
    }

    return firstMatchText(document.body?.innerText || "", /\b[A-Z][A-Z0-9]+-\d+\b/i)?.toUpperCase();
  }

  function extractTitle() {
    const selectors = [
      "#summary-val",
      "[data-testid='issue.views.issue-base.foundation.summary.heading']",
      "[data-testid*='summary'] h1",
      "[data-field-id='summary']",
      "h1"
    ];

    for (const selector of selectors) {
      const value = textFromSelector(selector);
      if (value) {
        return removeIssueKeyPrefix(value);
      }
    }

    const title = document.title
      .replace(/\s+-\s+Jira.*$/i, "")
      .replace(/\s+\|\s+Jira.*$/i, "");

    return removeIssueKeyPrefix(cleanText(title));
  }

  function extractFieldValue({ selectors, labels }) {
    for (const selector of selectors) {
      const value = textFromSelector(selector);
      if (value) {
        return value;
      }
    }

    return valueByLabels(labels);
  }

  function textFromSelector(selector) {
    const element = document.querySelector(selector);
    return cleanFieldValue(element?.innerText || element?.textContent || "");
  }

  function valueByLabels(labels) {
    const candidates = Array.from(document.querySelectorAll("dt, dd, label, strong, span, div, th, td"))
      .filter((element) => {
        const text = cleanText(element.textContent || "");
        return text.length > 0 && text.length <= 80 && labels.some((label) => isLabelText(text, label));
      });

    for (const labelElement of candidates) {
      const inlineValue = valueFromInlineLabel(labelElement, labels);
      if (inlineValue) {
        return inlineValue;
      }

      const siblingValue = valueFromSiblings(labelElement);
      if (siblingValue) {
        return siblingValue;
      }

      const containerValue = valueFromContainer(labelElement, labels);
      if (containerValue) {
        return containerValue;
      }
    }

    return "";
  }

  function valueFromInlineLabel(element, labels) {
    const text = cleanText(element.textContent || "");
    for (const label of labels) {
      const pattern = new RegExp(`^${escapeRegExp(label)}\\s*[:：]\\s*(.+)$`, "i");
      const match = text.match(pattern);
      const value = cleanFieldValue(match?.[1] || "");
      if (value && !isKnownLabel(value, labels)) {
        return value;
      }
    }

    return "";
  }

  function valueFromSiblings(element) {
    let sibling = element.nextElementSibling;
    while (sibling) {
      const value = cleanFieldValue(sibling.innerText || sibling.textContent || "");
      if (value) {
        return value;
      }

      sibling = sibling.nextElementSibling;
    }

    return "";
  }

  function valueFromContainer(element, labels) {
    const preferredSelectors = [
      ".value",
      "[id$='-val']",
      "[id$='-field']",
      "[data-testid*='field-value']",
      "dd",
      "a",
      "span"
    ];

    let container = element.parentElement;
    for (let depth = 0; container && depth < 5; depth += 1, container = container.parentElement) {
      for (const selector of preferredSelectors) {
        const values = Array.from(container.querySelectorAll(selector))
          .filter((candidate) => candidate !== element && !element.contains(candidate))
          .map((candidate) => cleanFieldValue(candidate.innerText || candidate.textContent || ""))
          .filter((value) => value && !isKnownLabel(value, labels));

        if (values.length > 0) {
          return values[0];
        }
      }

      const labelText = cleanText(element.textContent || "");
      const containerText = cleanFieldValue((container.innerText || container.textContent || "").replace(labelText, ""));
      if (containerText && !isKnownLabel(containerText, labels)) {
        return containerText;
      }
    }

    return "";
  }

  function isLabelText(text, label) {
    const normalizedText = normalizeLabel(text);
    const normalizedLabel = normalizeLabel(label);
    return normalizedText === normalizedLabel || normalizedText === `${normalizedLabel}:`;
  }

  function isKnownLabel(value, labels) {
    return labels.some((label) => isLabelText(value, label));
  }

  function cleanFieldValue(value) {
    const text = cleanText(value)
      .replace(/\s*\(查看工作流\)\s*/g, "")
      .replace(/^[:：]\s*/, "");

    return dedupeRepeatedTokens(text);
  }

  function cleanText(value) {
    return String(value || "")
      .replace(/\u00a0/g, " ")
      .replace(/[\u200b-\u200d\ufeff]/g, "")
      .replace(/\s+/g, " ")
      .trim();
  }

  function normalizeLabel(value) {
    return cleanText(value)
      .replace(/[:：]$/, "")
      .toLowerCase();
  }

  function removeIssueKeyPrefix(value) {
    return cleanText(value)
      .replace(/^[A-Z][A-Z0-9]+-\d+\s*[:：\-]\s*/i, "")
      .replace(/^(.+?)\s*\/\s*[A-Z][A-Z0-9]+-\d+\s*/i, "");
  }

  function dedupeRepeatedTokens(value) {
    const tokens = value.split(/\s+/);
    if (tokens.length === 2 && tokens[0] === tokens[1]) {
      return tokens[0];
    }

    return value;
  }

  function firstMatchText(text, pattern) {
    return text.match(pattern)?.[0] || "";
  }

  function compactPayload(payload) {
    return Object.fromEntries(
      Object.entries(payload).map(([key, value]) => [key, typeof value === "string" ? cleanText(value) : value])
    );
  }

  function escapeRegExp(value) {
    return String(value).replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  }
})();

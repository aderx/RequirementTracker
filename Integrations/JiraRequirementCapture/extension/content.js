(() => {
  if (window.__jiraRequirementCaptureInstalled) {
    return;
  }

  window.__jiraRequirementCaptureInstalled = true;

  chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
    if (message?.type !== "EXTRACT_REQUIREMENT_PAGE") {
      return false;
    }

    try {
      sendResponse({
        ok: true,
        result: extractRequirementPage(message.settings || {})
      });
    } catch (error) {
      sendResponse({
        ok: false,
        error: error?.message || "页面识别失败"
      });
    }

    return true;
  });

  function extractRequirementPage(settings) {
    const pageURL = normalizedURL(location.href);
    const jiraBaseURL = settings.jiraBaseURL || "http://jira.zstack.io/browse/";
    const jiraHost = hostFromURL(jiraBaseURL);
    const mrHosts = Array.isArray(settings.mrHosts) ? settings.mrHosts : ["gitlab.zstack.io"];

    const detailIssueKey = issueKeyFromJiraDetailURL(pageURL);
    if (detailIssueKey && (!jiraHost || location.hostname === jiraHost)) {
      return {
        pageType: "jira",
        payload: extractJiraRequirement(detailIssueKey, pageURL)
      };
    }

    if (jiraHost && location.hostname === jiraHost) {
      return {
        pageType: "unsupported",
        reason: "当前 Jira 页面不是详情页"
      };
    }

    if (isMRPage(pageURL, mrHosts)) {
      const jiraURL = findLinkedJiraURL(jiraBaseURL);
      return {
        pageType: "mr",
        payload: compactPayload({
          mrURL: pageURL,
          jiraURL,
          issueKey: jiraURL ? jiraKeyFromText(jiraURL) : "",
          capturedAt: new Date().toISOString()
        })
      };
    }

    return {
      pageType: "unsupported",
      reason: "当前页面暂不支持"
    };
  }

  function extractJiraRequirement(issueKey, pageURL) {
    return compactPayload({
      issueKey,
      jiraKey: issueKey,
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
      jiraURL: pageURL,
      url: pageURL,
      capturedAt: new Date().toISOString()
    });
  }

  function issueKeyFromJiraDetailURL(value) {
    return normalizedURL(value).match(/\/browse\/([A-Z][A-Z0-9]+-\d+)(?:\/)?$/i)?.[1]?.toUpperCase() || "";
  }

  function jiraKeyFromText(value) {
    return String(value || "").match(/\b[A-Z][A-Z0-9]+-\d+\b/i)?.[0]?.toUpperCase() || "";
  }

  function isMRPage(pageURL, mrHosts) {
    const host = location.hostname.toLowerCase();
    return mrHosts.map((value) => String(value || "").toLowerCase()).includes(host)
      && /\/-\/merge_requests\/\d+(?:\/)?$/i.test(pageURL);
  }

  function findLinkedJiraURL(jiraBaseURL) {
    const jiraHost = hostFromURL(jiraBaseURL);
    const links = Array.from(document.querySelectorAll("a[href]"));
    for (const link of links) {
      const href = link.href || "";
      const key = jiraKeyFromText(href);
      if (!key) {
        continue;
      }

      const normalized = normalizedURL(href);
      if (jiraHost && hostFromURL(normalized) === jiraHost && /\/browse\//i.test(normalized)) {
        return normalized;
      }
    }

    return "";
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

  function compactPayload(payload) {
    return Object.fromEntries(
      Object.entries(payload).map(([key, value]) => [key, typeof value === "string" ? cleanText(value) : value])
        .filter(([, value]) => value !== "")
    );
  }

  function escapeRegExp(value) {
    return String(value).replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  }
})();

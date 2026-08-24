(() => {
  if (window.__jiraRequirementCaptureInstalled) {
    return;
  }

  window.__jiraRequirementCaptureInstalled = true;

  chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
    if (message?.type === "EXTRACT_PAGE_OWNERSHIP") {
      sendResponse({
        ok: true,
        ownership: extractPageOwnership(message.pageType)
      });
      return false;
    }

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

  function extractPageOwnership(pageType) {
    if (pageType === "jira") {
      const assigneeText = textFromSelector("#assignee-val")
        || textFromSelector("[data-field-id='assignee']");
      if (/^(未分配|无|unassigned|none)$/i.test(cleanText(assigneeText))) {
        return "other";
      }

      return comparePageIdentities(
        identityFromSelectors([
          "#assignee-val",
          "#assignee-field",
          "[data-field-id='assignee']",
          "[data-testid*='assignee']"
        ]),
        identityFromSelectors([
          "#header-details-user-fullname",
          "[data-testid='user-menu--trigger']",
          "[data-testid='user-menu-toggle']",
          "meta[name='current-user-id']",
          "meta[name='user-login']"
        ])
      );
    }

    if (pageType === "mr") {
      return comparePageIdentities(
        identityFromSelectors([
          "[data-testid='issuable-author']",
          "[data-testid='author-link']",
          ".issuable-meta .author-link",
          ".detail-page-header .author-link",
          ".issuable-meta .js-user-link"
        ]),
        identityFromSelectors([
          "[data-testid='user-menu-toggle']",
          ".header-user-dropdown-toggle",
          ".current-user",
          "meta[name='current-user-id']",
          "meta[name='user-login']"
        ])
      );
    }

    return "unknown";
  }

  function identityFromSelectors(selectors) {
    const identity = { strong: new Set(), weak: new Set() };
    for (const selector of selectors) {
      const element = document.querySelector(selector);
      if (!element) {
        continue;
      }

      addIdentityTokens(identity, element);
      const descendants = typeof element.querySelectorAll === "function"
        ? Array.from(element.querySelectorAll(
          "[data-user-id], [data-username], [data-user], [data-login], [data-account-id], [data-user-key], a[href], img[alt]"
        ))
        : [];
      descendants.forEach((candidate) => addIdentityTokens(identity, candidate));
    }
    return identity;
  }

  function addIdentityTokens(identity, element) {
    const attribute = (name) => {
      if (typeof element.getAttribute === "function") {
        return element.getAttribute(name) || "";
      }
      return element[name] || "";
    };
    const strongAttributes = [
      ["data-user-id", "id"],
      ["data-account-id", "id"],
      ["data-user-key", "id"],
      ["data-username", "username"],
      ["data-user", "username"],
      ["data-login", "username"]
    ];

    for (const [name, kind] of strongAttributes) {
      const token = normalizeIdentityToken(attribute(name));
      if (token) {
        identity.strong.add(`${kind}:${token}`);
        identity.weak.add(token);
      }
    }

    const content = normalizeIdentityToken(attribute("content"));
    if (content) {
      const kind = /id/i.test(attribute("name")) ? "id" : "username";
      identity.strong.add(`${kind}:${content}`);
    }

    const href = String(element.href || attribute("href") || "");
    const hrefUsername = href.match(/\/(?:users|u)\/([^/?#]+)/i)?.[1]
      || href.match(/[?&](?:name|username)=([^&#]+)/i)?.[1];
    const normalizedHrefUsername = normalizeIdentityToken(hrefUsername || "");
    if (normalizedHrefUsername) {
      identity.strong.add(`username:${normalizedHrefUsername}`);
    }

    for (const value of [
      element.innerText,
      element.textContent,
      attribute("title"),
      attribute("alt")
    ]) {
      const token = normalizeIdentityText(value);
      if (token) {
        identity.weak.add(token);
      }
    }
  }

  function comparePageIdentities(subject, currentUser) {
    if (setsIntersect(subject.strong, currentUser.strong)) {
      return "mine";
    }

    const comparableStrongKinds = ["id", "username"].filter((kind) => {
      const prefix = `${kind}:`;
      return Array.from(subject.strong).some((value) => value.startsWith(prefix))
        && Array.from(currentUser.strong).some((value) => value.startsWith(prefix));
    });
    if (comparableStrongKinds.length > 0) {
      return "other";
    }

    if (setsIntersect(subject.weak, currentUser.weak)) {
      return "mine";
    }

    if (subject.weak.size > 0 && currentUser.weak.size > 0) {
      return "other";
    }

    return "unknown";
  }

  function setsIntersect(lhs, rhs) {
    return Array.from(lhs).some((value) => rhs.has(value));
  }

  function normalizeIdentityToken(value) {
    return cleanText(value)
      .replace(/^@/, "")
      .toLowerCase();
  }

  function normalizeIdentityText(value) {
    const normalized = cleanText(value)
      .replace(/^(?:经办人|提交人|作者|assignee|author)\s*[:：]?\s*/i, "")
      .replace(/(?:的个人信息|的头像)$/i, "")
      .replace(/(?:'s)?\s+(?:profile|avatar)$/i, "")
      .replace(/^@/, "")
      .toLowerCase();
    if (!normalized || /^(?:用户菜单|个人资料|user menu|profile|account)$/.test(normalized)) {
      return "";
    }
    return normalized;
  }

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
      const linkedJiraURL = findLinkedJiraURL(jiraBaseURL);
      const titleIssueKey = linkedJiraURL ? "" : findTitleJiraKey();
      const issueKey = linkedJiraURL ? jiraKeyFromText(linkedJiraURL) : titleIssueKey;
      const jiraURL = linkedJiraURL || (issueKey ? jiraURLForKey(jiraBaseURL, issueKey) : "");
      return {
        pageType: "mr",
        payload: compactPayload({
          mrURL: canonicalMRURL(pageURL),
          mrState: extractMRState(),
          jiraURL,
          issueKey,
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

  // MR 的 diffs/commits/pipelines 等子页同样按 MR 页面处理。
  function isMRPage(pageURL, mrHosts) {
    const host = location.hostname.toLowerCase();
    return mrHosts.map((value) => String(value || "").toLowerCase()).includes(host)
      && /\/-\/merge_requests\/\d+(?:\/[a-z_]+)?$/i.test(pageURL);
  }

  // 子页地址统一归到 MR 主地址，保证保存与匹配一致。
  function canonicalMRURL(value) {
    return String(value || "").replace(/(\/-\/merge_requests\/\d+)\/[a-z_]+$/i, "$1");
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

  function findTitleJiraKey() {
    const selectors = [
      "[data-testid='issuable-title']",
      "[data-testid*='issuable-title']",
      ".issuable-title",
      "h1"
    ];

    for (const selector of selectors) {
      const title = textFromSelector(selector);
      const key = hashPrefixedJiraKey(title);
      if (key) {
        return key;
      }
    }

    return hashPrefixedJiraKey(document.title);
  }

  function hashPrefixedJiraKey(value) {
    return String(value || "").match(/#\s*([A-Z][A-Z0-9]+-\d+)\b/i)?.[1]?.toUpperCase() || "";
  }

  function jiraURLForKey(jiraBaseURL, issueKey) {
    const baseURL = normalizedURL(jiraBaseURL);
    return (baseURL.endsWith("/") ? baseURL : baseURL + "/") + issueKey;
  }

  function extractMRState() {
    const selectors = [
      "[data-testid*='merge-request-state']",
      "[data-testid*='issuable-state']",
      "[data-testid*='state']",
      ".issuable-status-box",
      ".status-box",
      "[class*='issuable-status']",
      "[class*='merge-request-status']"
    ];

    for (const selector of selectors) {
      const values = Array.from(document.querySelectorAll(selector))
        .map((element) => cleanText(element.innerText || element.textContent || ""))
        .filter(Boolean);

      for (const value of values) {
        const state = normalizeMRState(value);
        if (state) {
          return state;
        }
      }
    }

    return normalizeMRState(document.body?.innerText?.slice(0, 4000) || "");
  }

  function normalizeMRState(value) {
    const text = cleanText(value).toLowerCase();
    if (!text) {
      return "";
    }

    if (/\bmerged\b|已合并/.test(text)) {
      return "merged";
    }

    if (/\bopen\b|已打开|开启中|进行中/.test(text)) {
      return "open";
    }

    if (/\bclosed\b|已关闭/.test(text)) {
      return "closed";
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

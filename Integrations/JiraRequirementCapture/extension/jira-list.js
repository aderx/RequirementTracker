(() => {
  if (window.__requirementTrackerInlineListInstalled) return;
  window.__requirementTrackerInlineListInstalled = true;

  const names = {
    pending: "待开发", active: "开发中", done: "开发完成", tested: "已自测",
    merged: "已合并", paused: "已暂停", stopped: "已停止"
  };
  const tooltipID = "rt-requirement-status-tooltip";
  const badgeClass = "rt-requirement-inline-status";
  const cache = new Map();
  const badges = new Map();
  // 显示选择只属于本次文档，刷新后恢复默认，不写入浏览器存储。
  let enabled = true;
  let timer;
  let positionFrame;
  let tooltipLink = null;
  let loading = false;
  let refreshAgain = false;
  let forceNext = false;
  // 重载开发插件时，只清理本插件上一版留下的节点。
  document.getElementById("rt-requirement-overlays")?.remove();
  document.getElementById(tooltipID)?.remove();
  for (const badge of document.querySelectorAll(`.rt-requirement-status, .${badgeClass}`)) badge.remove();
  const tooltip = document.createElement("div");
  tooltip.id = tooltipID;
  tooltip.setAttribute("role", "tooltip");
  tooltip.hidden = true;
  const tooltipIcon = createIcon();
  const tooltipLabel = document.createElement("span");
  tooltip.appendChild(tooltipIcon);
  tooltip.appendChild(tooltipLabel);
  document.documentElement.appendChild(tooltip);
  const resizeObserver = new ResizeObserver(schedulePosition);

  function createIcon() {
    const icon = document.createElement("canvas");
    icon.width = 64;
    icon.height = 64;
    icon.setAttribute("aria-hidden", "true");
    return icon;
  }

  // 图标没有文本节点，编号仍可按原始文本识别，不给摘要链接重复加标记。
  function targets() {
    const result = [];
    const rows = new Set();
    for (const link of document.querySelectorAll("a[href*='/browse/']")) {
      const url = new URL(link.href, location.href);
      const key = url.pathname.match(/^\/browse\/([A-Z][A-Z0-9]+-\d+)\/?$/i)?.[1]?.toUpperCase();
      const row = link.closest("tr, .issue-list-item");
      if (url.origin !== location.origin || !key || !row || rows.has(row)
          || link.textContent.trim().toUpperCase() !== key) continue;
      rows.add(row);
      result.push({ link, key, row });
    }
    return result;
  }

  function render() {
    if (!enabled) return;
    const retained = new Set();
    for (const { link, key, row } of targets()) {
      let badgeEntry = badges.get(link);
      if (!badgeEntry) {
        const badge = document.createElement("span");
        badge.className = badgeClass;
        badge.setAttribute("role", "img");
        const icon = createIcon();
        badge.appendChild(icon);
        // 不替换链接、不改其属性，也不注册 click 处理器；图标点击仍交给原链接。
        const handlers = {
          mouseenter: () => showTooltip(link),
          mouseleave: () => hideTooltip(link),
          focus: () => showTooltip(link),
          blur: () => hideTooltip(link)
        };
        for (const [event, handler] of Object.entries(handlers)) link.addEventListener(event, handler);
        badgeEntry = { badge, icon, row, handlers };
        badges.set(link, badgeEntry);
        resizeObserver.observe(row);
      }
      retained.add(link);
      const { badge, icon } = badgeEntry;
      // Jira 更新同一链接的内容时，会移除扩展子节点；只补回图标，不重建链接。
      if (badge.parentElement !== link) link.appendChild(badge);
      badge.hidden = false;
      const entry = cache.get(key);
      const value = entry?.value;
      let state = "loading";
      let text = "读取中";
      let detail = "正在读取需求记录";
      if (entry?.error) {
        state = "error";
        text = "读取失败";
        detail = entry.error;
      } else if (value) {
        state = value.ambiguous ? "ambiguous" : !value.exists ? "missing" : value.status;
        text = state === "ambiguous" ? "多条记录" : state === "missing" ? "未记录" : names[state] || "未知状态";
        detail = value.ambiguous ? "同一 Jira 对应多条本地记录，请在 App 中确认" : `需求记录：${text}`;
        if (["paused", "stopped"].includes(state) && value.pauseReason) detail += `\n${value.pauseReason}`;
      }
      badge.dataset.state = state;
      const iconState = ["done", "tested", "merged", "paused", "stopped"].includes(state)
        ? state : state === "missing" ? "addable" : "recorded";
      if (badgeEntry.iconState !== iconState) {
        BadgeIconRenderer.drawBadgePreview(icon, iconState);
        badgeEntry.iconState = iconState;
      }
      badgeEntry.text = text;
      badgeEntry.detail = detail;
      badge.setAttribute("aria-label", detail);
    }
    for (const [link, { badge, row, handlers }] of badges) {
      if (!retained.has(link)) {
        hideTooltip(link);
        badge.remove();
        resizeObserver.unobserve(row);
        for (const [event, handler] of Object.entries(handlers)) link.removeEventListener(event, handler);
        badges.delete(link);
      }
    }
    if (tooltipLink) showTooltip(tooltipLink);
  }

  function showTooltip(link) {
    const entry = badges.get(link);
    if (!enabled || !link.isConnected || !entry) return;
    if (tooltipLink && tooltipLink !== link) hideTooltip(tooltipLink);
    tooltipLink = link;
    entry.badge.dataset.expanded = "true";
    tooltip.dataset.state = entry.badge.dataset.state;
    tooltip.setAttribute("aria-label", entry.detail);
    tooltipLabel.textContent = entry.text;
    BadgeIconRenderer.drawBadgePreview(tooltipIcon, entry.iconState);
    tooltip.hidden = false;
    positionTooltip();
  }

  function hideTooltip(link = tooltipLink) {
    if (tooltipLink !== link) return;
    const entry = badges.get(tooltipLink);
    if (entry) entry.badge.dataset.expanded = "false";
    tooltip.hidden = true;
    tooltipLink = null;
  }

  function positionTooltip() {
    const entry = badges.get(tooltipLink);
    if (!enabled || !entry) return;
    const rect = entry.badge.getBoundingClientRect();
    const clip = { left: 0, top: 0, right: window.innerWidth, bottom: window.innerHeight };
    // 图标跟随链接自然排版；只有提示框需要跟踪视口和嵌套滚动区。
    for (let element = tooltipLink.parentElement; element && element !== document.body; element = element.parentElement) {
      const style = window.getComputedStyle(element);
      const outer = element.getBoundingClientRect();
      if (/auto|scroll|hidden|clip/.test(style.overflowX)) {
        clip.left = Math.max(clip.left, outer.left + element.clientLeft);
        clip.right = Math.min(clip.right, outer.left + element.clientLeft + element.clientWidth);
      }
      if (/auto|scroll|hidden|clip/.test(style.overflowY)) {
        clip.top = Math.max(clip.top, outer.top + element.clientTop);
        clip.bottom = Math.min(clip.bottom, outer.top + element.clientTop + element.clientHeight);
      }
    }
    if (!entry.badge.isConnected || !rect.width || !rect.height || rect.right <= clip.left
        || rect.left >= clip.right || rect.bottom <= clip.top || rect.top >= clip.bottom) {
      hideTooltip();
      return;
    }
    const bounds = tooltip.getBoundingClientRect();
    const left = Math.max(8, Math.min(rect.left + (rect.width - bounds.width) / 2, window.innerWidth - bounds.width - 8));
    const preferredTop = rect.top - bounds.height - 8;
    const top = preferredTop >= 8 ? preferredTop : rect.bottom + 8;
    tooltip.style.left = `${Math.round(left)}px`;
    tooltip.style.top = `${Math.round(Math.max(8, Math.min(top, window.innerHeight - bounds.height - 8)))}px`;
  }

  function schedulePosition() {
    if (!enabled || !tooltipLink || positionFrame) return;
    positionFrame = requestAnimationFrame(() => {
      positionFrame = null;
      positionTooltip();
    });
  }

  function query(issueKeys) {
    return new Promise((resolve, reject) => {
      chrome.runtime.sendMessage({ type: "LOOKUP_REQUIREMENT_LIST", issueKeys }, (response) => {
        const error = chrome.runtime.lastError;
        if (error || !response?.ok) {
          reject(new Error(error?.message || response?.error || "读取本地状态失败"));
        } else {
          resolve(response.requirements);
        }
      });
    });
  }

  async function refresh(force) {
    if (!enabled || document.visibilityState === "hidden") return;
    if (loading) {
      refreshAgain = true;
      forceNext ||= force;
      return;
    }
    const now = Date.now();
    const keys = [...new Set(targets().map(({ key }) => key))].filter((key) =>
      force || !cache.has(key) || now - cache.get(key).time >= 30000
    );
    render();
    if (!keys.length) return;
    loading = true;
    try {
      for (let offset = 0; offset < keys.length; offset += 100) {
        if (!enabled) break;
        const batch = keys.slice(offset, offset + 100);
        try {
          const values = await query(batch);
          if (!Array.isArray(values)) throw new Error("本地状态响应无效");
          const byKey = new Map(values.map((value) => [value.issueKey, value]));
          for (const key of batch) {
            const value = byKey.get(key);
            cache.set(key, value
              ? { value, time: Date.now() }
              : { error: "未收到此需求的查询结果", time: Date.now() });
          }
        } catch (error) {
          for (const key of batch) cache.set(key, { error: error.message, time: Date.now() });
        }
      }
      render();
      const visibleKeys = new Set(targets().map(({ key }) => key));
      for (const key of cache.keys()) if (!visibleKeys.has(key)) cache.delete(key);
    } finally {
      loading = false;
      if (refreshAgain) {
        refreshAgain = false;
        schedule();
      }
    }
  }

  function schedule(force = false) {
    if (!enabled) return;
    forceNext ||= force;
    clearTimeout(timer);
    timer = setTimeout(() => {
      const requestedForce = forceNext;
      forceNext = false;
      void refresh(requestedForce);
    }, 250);
  }

  new MutationObserver((mutations) => {
    // 插入图标和更新提示框不触发下一轮查询；Jira 重画链接时仍会补回图标。
    const changed = mutations.some((mutation) => {
      const element = mutation.target.nodeType === 1 ? mutation.target : mutation.target.parentElement;
      if (element?.closest(`#${tooltipID}, .${badgeClass}`)) return false;
      if (mutation.type === "attributes" || mutation.type === "characterData") return true;
      if (mutation.removedNodes.length) return true;
      return [...mutation.addedNodes].some((node) => node.nodeType !== 1
        || (node.id !== tooltipID && !node.classList.contains(badgeClass)));
    });
    if (changed) schedule();
  }).observe(document.documentElement, {
    subtree: true, childList: true, characterData: true, attributes: true, attributeFilter: ["href"]
  });
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "hidden") hideTooltip();
    schedule(true);
  });
  document.addEventListener("scroll", schedulePosition, { capture: true, passive: true });
  document.addEventListener("keydown", (event) => {
    if (event.key === "Escape") hideTooltip();
  });
  window.addEventListener("resize", schedulePosition);
  window.addEventListener("focus", () => schedule(true));
  chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
    if (message?.type === "REFRESH_REQUIREMENT_LIST") schedule(true);
    if (message?.type === "GET_REQUIREMENT_LIST_VISIBILITY") sendResponse({ ok: true, enabled });
    if (message?.type === "SET_REQUIREMENT_LIST_VISIBILITY" && typeof message.enabled === "boolean") {
      enabled = message.enabled;
      if (enabled) {
        render();
        schedule(true);
      } else {
        clearTimeout(timer);
        hideTooltip();
        for (const { badge } of badges.values()) badge.hidden = true;
      }
      sendResponse({ ok: true, enabled });
    }
  });
  setInterval(() => schedule(true), 30000);
  schedule();
})();

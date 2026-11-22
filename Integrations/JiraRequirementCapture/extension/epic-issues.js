(() => {
  // 弹窗和内容脚本都可能注入工具栏。通过 DOM 复用仍在工作的多选控件，包括扩展重载后的离线标签页。
  const probe = new Event("requirement-tracker:epic-multiselect", { cancelable: true });
  if (!document.dispatchEvent(probe)) return;
  document.addEventListener(probe.type, event => event.preventDefault());

  const tableSelector = "#greenhopper-epics-issue-web-panel #ghx-issues-in-epic-table";
  const fields = { type: "类型", status: "状态", assignee: "经办人" };
  const iconPaths = {
    type: "m8 1.5 6 3.3-6 3.3-6-3.3L8 1.5Zm-6 6.4 6 3.3 6-3.3M2 11l6 3.3 6-3.3",
    status: "M14 8A6 6 0 1 1 8 2m0 0v6l4.3 2.5M11 2.8l.8.5m1.5 1.9.4.8",
    assignee: "M10.8 5.2a2.8 2.8 0 1 1-5.6 0 2.8 2.8 0 0 1 5.6 0ZM2.5 14c.3-3 2.4-4.5 5.5-4.5s5.2 1.5 5.5 4.5",
    refresh: "M13.6 2.6v3.8H9.8M2.4 13.4V9.6h3.8M13.3 6A5.6 5.6 0 0 0 3.1 4.8M2.7 10a5.6 5.6 0 0 0 10.2 1.2",
    sort: "M4 13V2.5M1.7 4.8 4 2.5l2.3 2.3M8.5 4H14M8.5 8H13M8.5 12h3",
    reset: "M2.5 3v4h4M2.8 6.5A5.3 5.3 0 1 1 4.3 12"
  };

  function icon(name) {
    const ns = "http://www.w3.org/2000/svg";
    const svg = document.createElementNS(ns, "svg");
    svg.setAttribute("viewBox", "0 0 16 16");
    svg.setAttribute("aria-hidden", "true");
    const path = document.createElementNS(ns, "path");
    path.setAttribute("d", iconPaths[name]);
    svg.append(path);
    return svg;
  }

  let view;
  let frame;
  let tableChanged = false;

  function readSession(key) {
    try { return JSON.parse(sessionStorage.getItem(key)) || {}; }
    catch { return {}; }
  }

  function saveSession(key, value) {
    try {
      if (value) sessionStorage.setItem(key, JSON.stringify(value));
      else sessionStorage.removeItem(key);
    } catch { /* 禁用会话存储时仍可操作当前列表。 */ }
  }

  function scrollPane(table) {
    for (let node = table.parentElement; node && node !== document.scrollingElement; node = node.parentElement) {
      if (/^(auto|scroll|overlay)$/.test(getComputedStyle(node).overflowY)) return node;
    }
    return null;
  }

  function restoreScroll(table, key) {
    const pos = readSession(key);
    if (!Number.isFinite(pos.y)) return;
    saveSession(key, null);
    const cancel = new AbortController();
    for (const event of ["wheel", "touchstart", "pointerdown", "keydown"]) {
      window.addEventListener(event, () => cancel.abort(), { passive: true, once: true, signal: cancel.signal });
    }
    // Jira 的滚动条在详情容器内，等筛选和页面布局就绪再恢复两个滚动位置。
    function afterLoad() {
      const deadline = performance.now() + 2500;
      function restore() {
        if (!table.isConnected || cancel.signal.aborted) { cancel.abort(); return; }
        const pane = scrollPane(table);
        window.scrollTo(pos.x, pos.y);
        if (pane) pane.scrollTo(pos.left, pos.top);
        if ((Math.abs(window.scrollY - pos.y) > 1 || (pane && Math.abs(pane.scrollTop - pos.top) > 1))
            && performance.now() < deadline) {
          setTimeout(restore, 75);
        } else cancel.abort();
      }
      requestAnimationFrame(() => requestAnimationFrame(restore));
    }
    if (document.readyState === "complete") afterLoad();
    else window.addEventListener("load", afterLoad, { once: true, signal: cancel.signal });
  }

  function sameOrder(a, b) {
    return a.length === b.length && a.every((row, i) => row === b[i]);
  }

  function orderRows(current, desired) {
    if (sameOrder(current, desired)) return;
    // 保留 Jira 的行节点、操作菜单和非问题行的位置。
    const slots = current.map(row => {
      const slot = document.createComment("");
      row.replaceWith(slot);
      return slot;
    });
    slots.forEach((slot, i) => slot.replaceWith(desired[i]));
  }

  function rowValues(row) {
    const icon = row.querySelector(".issuetype img");
    const cellText = selector => row.querySelector(selector)?.textContent.trim() || "";
    return {
      type: icon?.alt.trim() || icon?.title.trim() || cellText(".issuetype"),
      status: cellText(".jira-issue-status-lozenge") || cellText(".status"),
      assignee: cellText(".assignee")
    };
  }

  function makeFilter(field, title, onChange) {
    const group = document.createElement("div");
    group.className = "rt-epic-filter";
    const trigger = document.createElement("button");
    trigger.type = "button";
    trigger.className = "rt-epic-filter-toggle";
    const summary = document.createElement("strong");
    const more = document.createElement("span");
    more.className = "rt-epic-more";
    trigger.append(icon(field), title, summary, more);

    const menu = document.createElement("div");
    menu.className = "rt-epic-options";
    menu.popover = "auto";
    menu.setAttribute("role", "group");
    menu.setAttribute("aria-label", title);
    trigger.popoverTargetElement = menu;
    group.append(trigger, menu);

    function option(value, label) {
      const item = document.createElement("label");
      const input = document.createElement("input");
      input.type = "checkbox";
      input.value = value;
      item.append(input, label);
      return item;
    }
    const all = option("", "全部");
    menu.append(all);
    menu.addEventListener("change", event => {
      const selected = event.target.value
        ? Array.from(menu.querySelectorAll("input:checked"), input => input.value).filter(Boolean)
        : [];
      onChange(selected);
    });

    let previousOptions = [];
    function update(options, requested = []) {
      // 同一个 Epic 可能存有上一版的单个筛选值。
      const wanted = new Set(Array.isArray(requested) ? requested : [requested]);
      const selected = options.filter(value => wanted.has(value));
      if (!sameOrder(options, previousOptions)) {
        menu.replaceChildren(all, ...options.map(value => option(value, value)));
        previousOptions = options;
      }
      for (const input of menu.querySelectorAll("input")) {
        input.checked = input.value ? wanted.has(input.value) : !selected.length;
      }
      summary.textContent = selected[0] || "全部";
      more.hidden = selected.length < 2;
      more.textContent = more.hidden ? "" : `+${selected.length - 1}`;
      trigger.title = `${title}：${selected.join("、") || "全部"}`;
      trigger.setAttribute("aria-label", trigger.title);
      trigger.classList.toggle("is-active", selected.length > 0);
      return selected;
    }
    return { group, update };
  }

  function legacyToolbar(table) {
    const bar = table.previousElementSibling;
    return bar?.matches(".rt-epic-toolbar") ? bar : null;
  }

  function retireLegacy(bar, table) {
    // 旧单选脚本可能仍在监听表格。让它回到无筛选的正序，再把显示与会话交给多选工具栏。
    const reset = Array.from(bar.querySelectorAll("button")).find(button => button.textContent === "重置");
    reset?.click();
    bar.hidden = true;
    table.querySelectorAll(".rt-epic-filtered").forEach(row => row.classList.remove("rt-epic-filtered"));
  }

  function mount(table, issueKey) {
    const legacyKey = `requirementTracker.epic.${issueKey}`;
    const key = legacyKey + ".filters";
    const scrollKey = legacyKey + ".scroll";
    let state = readSession(key);
    if (!Object.keys(state).length) state = readSession(legacyKey);
    const legacy = legacyToolbar(table);
    if (legacy && !legacy.hidden) retireLegacy(legacy, table);
    const anchor = legacy || table;
    const preceding = anchor.previousElementSibling;
    const stale = preceding?.matches(".rt-epic-controls") ? preceding : null;
    let displayedInReverse = !!(stale || legacy)?.querySelector('button[aria-pressed="true"]');
    stale?.remove();
    let displayed = rows();
    let original = displayedInReverse ? [...displayed].reverse() : displayed;
    let hasRenderedRows = false;
    const bar = document.createElement("div");
    bar.className = "rt-epic-controls";
    bar.setAttribute("role", "group");
    bar.setAttribute("aria-label", "Epic 中的问题列表工具");
    const filters = document.createElement("div");
    filters.className = "rt-epic-filter-group";
    const tools = document.createElement("div");
    tools.className = "rt-epic-actions";
    bar.append(filters, tools);
    anchor.before(bar);

    const controls = {};
    for (const [field, title] of Object.entries(fields)) {
      controls[field] = makeFilter(field, title, selected => { state[field] = selected; render(); });
      filters.append(controls[field].group);
    }

    function button(parent, name, title, action) {
      const el = document.createElement("button");
      el.type = "button";
      el.className = "rt-epic-action";
      el.append(icon(name), title);
      el.addEventListener("click", action);
      parent.append(el);
      return el;
    }
    const sort = button(filters, "sort", "正序", () => {
      state.reverse = !state.reverse;
      render();
    });
    button(tools, "refresh", "刷新", () => {
      const pane = scrollPane(table);
      saveSession(scrollKey, { x: window.scrollX, y: window.scrollY, left: pane?.scrollLeft || 0, top: pane?.scrollTop || 0 });
      location.reload();
    });
    button(tools, "reset", "重置", () => { state = {}; render(); });
    const count = document.createElement("span");
    count.setAttribute("role", "status");
    count.title = "当前显示的问题数 / 问题总数";
    tools.append(count);

    function rows() {
      return Array.from(table.tBodies[0]?.rows || []).filter(row => row.matches(".issuerow"));
    }

    function render() {
      const current = rows();
      if (!sameOrder(current, displayed)) {
        const live = new Set(current);
        const known = new Set(original);
        // 倒序期间 Jira 追加的行在原顺序末尾；整个表体重绘时采用新表体的原始顺序。
        if (displayedInReverse && sameOrder(current.filter(row => known.has(row)), displayed.filter(row => live.has(row)))) {
          original = original.filter(row => live.has(row)).concat(current.filter(row => !known.has(row)));
        } else {
          original = current;
        }
      }
      const values = original.map(rowValues);
      const active = [];
      const saved = current.length ? {} : { ...state };
      for (const [field, control] of Object.entries(controls)) {
        const options = [...new Set(values.map(value => value[field]).filter(Boolean))];
        const selected = control.update(options, state[field]);
        if (selected.length) {
          active.push([field, new Set(selected)]);
          saved[field] = selected;
        }
      }
      let visible = 0;
      original.forEach((row, i) => {
        const matches = active.every(([field, selected]) => selected.has(values[i][field]));
        row.classList.toggle("rt-epic-excluded", !matches);
        if (matches) visible++;
      });
      displayed = state.reverse ? [...original].reverse() : original;
      displayedInReverse = !!state.reverse;
      orderRows(current, displayed);
      sort.lastChild.data = state.reverse ? "倒序" : "正序";
      sort.title = state.reverse ? "切换为 Jira 原顺序" : "反转当前列表顺序";
      sort.setAttribute("aria-pressed", String(!!state.reverse));
      count.textContent = `${visible} / ${current.length}`;
      if (state.reverse) saved.reverse = true;
      saveSession(key, Object.keys(saved).length ? saved : null);
      if (current.length && !hasRenderedRows) {
        hasRenderedRows = true;
        restoreScroll(table, scrollKey);
      }
      observer.takeRecords();
    }

    function remove() {
      const current = rows();
      const live = new Set(current);
      const known = new Set(original);
      orderRows(current, original.filter(row => live.has(row)).concat(current.filter(row => !known.has(row))));
      current.forEach(row => row.classList.remove("rt-epic-excluded"));
      bar.remove();
    }
    saveSession(legacyKey, null);
    return { table, issueKey, render, remove };
  }

  function reconcile() {
    frame = null;
    const issueKey = location.pathname.match(/^\/browse\/([A-Z][A-Z0-9]+-\d+)\/?$/i)?.[1].toUpperCase();
    const type = document.querySelector("#type-val, #issuetype-val, [data-field-id='issuetype']");
    const isEpic = [type?.textContent, type?.querySelector("img")?.alt].some(value => /^epic$/i.test(value?.trim()));
    const table = issueKey && isEpic && document.querySelector(tableSelector);
    if (view && (view.issueKey !== issueKey || view.table !== table)) { view.remove(); view = null; }
    if (!table) return;
    if (!view) {
      view = mount(table, issueKey);
      tableChanged = true;
    } else {
      const legacy = legacyToolbar(table);
      if (legacy && !legacy.hidden) { retireLegacy(legacy, table); tableChanged = true; }
    }
    if (tableChanged) view.render();
    tableChanged = false;
  }

  const observer = new MutationObserver(changes => {
    if (view && changes.some(change => view.table.contains(change.target))) tableChanged = true;
    if (!frame) frame = requestAnimationFrame(reconcile);
  });
  observer.observe(document.documentElement, {
    subtree: true, childList: true, characterData: true, attributes: true, attributeFilter: ["alt", "title"]
  });
  reconcile();
})();

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const source = fs.readFileSync(path.join(__dirname, "jira-list.js"), "utf8");

function page() {
  let links = [];
  let observer;
  let resize;
  let nextTimer = 0;
  const timers = new Map();
  const events = {};
  const calls = [];
  const responses = new Map();
  const badgeDraws = [];
  let error = "";
  let defer = false;
  const pending = [];
  function makeElement(tagName = "div") {
    const listeners = new Map();
    const element = {
      nodeType: 1, tagName, className: "", dataset: {}, style: {}, childNodes: [],
      hidden: false, parentElement: null,
      clientLeft: 0, clientTop: 0, clientWidth: 1000, clientHeight: 600,
      rect: { left: 0, right: 1000, top: 80, bottom: 680, width: 1000, height: 600 },
      get children() { return this.childNodes.filter((child) => child.nodeType === 1); },
      get isConnected() { return this === html || !!this.parentElement?.isConnected; },
      get textContent() { return this.childNodes.map((child) => child.textContent).join(""); },
      set textContent(text) {
        for (const child of this.childNodes) child.parentElement = null;
        this.childNodes = text ? [{ nodeType: 3, textContent: text, parentElement: this }] : [];
      },
      get classList() { return { contains: (name) => this.className.split(" ").includes(name) }; },
      setAttribute(name, value) { this[name] = value; },
      appendChild(child) {
        child.remove?.();
        this.childNodes.push(child);
        child.parentElement = this;
      },
      getBoundingClientRect() {
        if (this.className === "rt-requirement-inline-status") {
          const anchor = this.parentElement.rect;
          return { left: anchor.right + 4, right: anchor.right + 18,
            top: anchor.top + 3, bottom: anchor.top + 17, width: 14, height: 14 };
        }
        if (this.id === "rt-requirement-status-tooltip") return { width: 100, height: 34 };
        return this.rect;
      },
      matches(selector) {
        return selector.split(/,\s*/).some((part) => part.startsWith("#") ? this.id === part.slice(1)
          : part.startsWith(".") ? this.classList.contains(part.slice(1)) : this.tagName === part);
      },
      closest(selector) {
        return this.matches(selector) ? this : this.parentElement?.closest(selector);
      },
      addEventListener(name, handler) {
        if (!listeners.has(name)) listeners.set(name, new Set());
        listeners.get(name).add(handler);
      },
      removeEventListener(name, handler) { listeners.get(name)?.delete(handler); },
      dispatch(name) {
        const event = { defaultPrevented: false, preventDefault() { this.defaultPrevented = true; } };
        for (const handler of listeners.get(name) || []) handler(event);
        return event;
      },
      remove() {
        if (this.parentElement) this.parentElement.childNodes = this.parentElement.childNodes.filter((child) => child !== this);
        this.parentElement = null;
      }
    };
    return element;
  }
  const html = makeElement();
  const body = makeElement();
  const scroller = makeElement();
  scroller.overflow = "auto";
  body.appendChild(scroller);
  html.appendChild(body);
  const legacyBadge = makeElement();
  legacyBadge.className = "rt-requirement-status";
  body.appendChild(legacyBadge);
  const document = {
    visibilityState: "visible", documentElement: html, body,
    getElementById: (id) => html.children.find((child) => child.id === id),
    querySelectorAll: (selector) => selector.startsWith("a[") ? links
      : selector.includes(".rt-requirement-status") && legacyBadge.isConnected ? [legacyBadge] : [],
    createElement: makeElement,
    addEventListener: (name, handler) => { events[name] = handler; }
  };
  const sandbox = {
    document, URL, console,
    location: { href: "http://jira.zstack.io/issues/?filter=-1", origin: "http://jira.zstack.io" },
    window: {
      innerWidth: 1200, innerHeight: 800,
      getComputedStyle: (element) => ({ overflowX: element.overflow || "visible", overflowY: element.overflow || "visible" }),
      addEventListener: (name, handler) => { events[name] = handler; }
    },
    BadgeIconRenderer: { drawBadgePreview: (canvas, state) => { canvas.drawnState = state; badgeDraws.push(state); } },
    MutationObserver: class { constructor(callback) { observer = callback; } observe() {} },
    ResizeObserver: class { constructor(callback) { resize = callback; } observe() {} unobserve() {} },
    requestAnimationFrame: (callback) => { timers.set(++nextTimer, callback); return nextTimer; },
    setTimeout: (callback) => { timers.set(++nextTimer, callback); return nextTimer; },
    clearTimeout: (id) => timers.delete(id),
    setInterval: (callback) => { events.interval = callback; },
    chrome: { runtime: {
      onMessage: { addListener: (handler) => { events.message = handler; } },
      sendMessage: (message, callback) => {
        calls.push(message);
        const answer = () => callback(error ? { ok: false, error } : {
          ok: true,
          requirements: message.issueKeys.map((issueKey) => ({ issueKey, ...(responses.get(issueKey) || { exists: false }) }))
        });
        if (defer) pending.push(answer); else answer();
      }
    } }
  };
  vm.createContext(sandbox);
  const inject = () => vm.runInContext(source, sandbox);
  inject();
  const root = document.getElementById("rt-requirement-status-tooltip");
  function setRows(keys) {
    for (const row of scroller.children) row.remove();
    links = keys.flatMap((key, index) => {
      const row = makeElement("tr");
      scroller.appendChild(row);
      const cell = makeElement("td");
      cell.overflow = "hidden";
      cell.clientWidth = 260;
      row.appendChild(cell);
      const link = makeElement("a");
      link.href = `http://jira.zstack.io/browse/${key}`;
      link.target = "_blank";
      link.title = `查看 ${key}`;
      link.dataset.issueKey = key;
      link.textContent = key;
      link.clicks = 0;
      link.addEventListener("click", () => { link.clicks += 1; });
      link.rect = { left: 100, right: 200, top: 110 + index * 40, bottom: 130 + index * 40, width: 100, height: 20 };
      link.after = () => assert.fail("The icon belongs inside the original key link");
      cell.appendChild(link);
      const summary = makeElement("a");
      summary.href = link.href;
      summary.textContent = "需求摘要链接";
      row.appendChild(summary);
      return [link, summary];
    });
    observer([{ target: scroller, addedNodes: [makeElement()], removedNodes: [] }]);
  }
  async function flush() {
    for (let n = 0; n < 8; n++) {
      for (const [id, callback] of [...timers]) { timers.delete(id); callback(); }
      await Promise.resolve();
    }
    assert.equal(timers.size, 0, "Rendering must settle without an observer loop");
  }
  function message(value) {
    let result;
    events.message(value, {}, (response) => { result = response; });
    return result;
  }
  return {
    calls, responses, events, root, legacyBadge, setRows, flush, pending, badgeDraws, inject, message,
    rows: () => scroller.children,
    links: () => links.filter((link) => link.dataset.issueKey),
    badges: () => links.flatMap((link) => link.children),
    moveRows: (dx, dy) => {
      for (const link of links) {
        link.rect.left += dx; link.rect.right += dx; link.rect.top += dy; link.rect.bottom += dy;
      }
    },
    resize: () => resize(),
    setError: (value) => { error = value; },
    setDeferred: (value) => { defer = value; },
    hide: (value) => { document.visibilityState = value ? "hidden" : "visible"; },
    mutateBadge: () => observer([{ target: links[0].children[0], addedNodes: [], removedNodes: [] }]),
    redrawLink: () => {
      const link = links[0];
      const removedNodes = [...link.childNodes];
      link.textContent = link.dataset.issueKey;
      observer([{ type: "childList", target: link, addedNodes: [...link.childNodes], removedNodes }]);
    }
  };
}

async function run() {
  const view = page();
  view.responses.set("ZSTAC-1", { exists: true, status: "paused", pauseReason: "等待接口" });
  view.responses.set("ZSTAC-2", { exists: true, ambiguous: true });
  view.setRows(["ZSTAC-1", "ZSTAC-2", "ZSTAC-3"]);
  const originalChildren = view.rows().map((row) => [...row.children]);
  const originalLinks = [...view.links()];
  const originalText = originalLinks.map((link) => link.childNodes[0]);
  const originalAttributes = originalLinks.map(({ href, target, title, dataset, style }) =>
    ({ href, target, title, dataset: { ...dataset }, style: { ...style } }));
  await view.flush();
  assert.equal(view.calls.length, 1, "All keys use one batch");
  assert.equal(view.badges().length, 3, "Summary links must not get duplicate badges");
  assert.deepEqual(view.rows().map((row) => row.children), originalChildren, "Original row contents stay untouched");
  for (const [index, link] of view.links().entries()) {
    assert.equal(link, originalLinks[index], "Keep the original anchor node");
    assert.equal(link.childNodes[0], originalText[index], "Keep the original number text node");
    assert.equal(link.textContent, link.dataset.issueKey, "Copying the number must not include status text");
    assert.equal(link.childNodes.at(-1), view.badges()[index], "The icon follows the original contents inside the anchor");
    const { href, target, title, dataset, style } = link;
    assert.deepEqual({ href, target, title, dataset, style }, originalAttributes[index]);
    assert.equal(link.dispatch("click").defaultPrevented, false, "Do not cancel link navigation");
    assert.equal(link.clicks, 1, "Keep Jira's existing click handler");
  }
  assert.equal(view.legacyBadge.isConnected, false, "Only old extension-owned markers are removed");
  assert.deepEqual(view.badges().map((badge) => badge.dataset.state), ["paused", "ambiguous", "missing"]);
  assert.deepEqual(view.badges().map((badge) => badge.children[0].drawnState), ["paused", "recorded", "addable"]);
  assert.match(view.badges()[0]["aria-label"], /需求记录：已暂停\n等待接口/);
  assert.equal(view.root.hidden, true);
  view.links()[0].dispatch("mouseenter");
  assert.equal(view.root.hidden, false);
  assert.equal(view.root.children[0].drawnState, "paused");
  assert.equal(view.root.children[1].textContent, "已暂停");
  assert.equal(view.root.closest("a"), undefined, "The tooltip never participates in the link/table layout");
  assert.equal(view.badges()[0].dataset.expanded, "true");
  assert.equal(view.root.style.left, "161px");
  assert.equal(view.root.style.top, "71px");
  view.mutateBadge();
  await view.flush();
  assert.equal(view.calls.length, 1, "Own rendering must not re-query");

  view.moveRows(20, -10);
  view.events.scroll();
  view.events.scroll();
  await view.flush();
  assert.equal(view.root.style.left, "181px");
  assert.equal(view.root.style.top, "61px");
  assert.equal(view.calls.length, 1, "Scrolling only repositions the tooltip");
  view.moveRows(0, -40);
  view.events.scroll();
  await view.flush();
  assert.equal(view.root.hidden, true, "Hide the tooltip when its icon leaves the nested scroll container");
  view.moveRows(0, 50);
  view.resize();
  await view.flush();
  view.links()[0].dispatch("focus");
  assert.equal(view.root.hidden, false, "Keyboard focus also shows the full status");
  view.events.keydown({ key: "Escape" });
  assert.equal(view.root.hidden, true);
  view.links()[0].dispatch("mouseenter");
  view.links()[0].dispatch("mouseleave");
  assert.equal(view.root.hidden, true);
  const existingBadge = view.badges()[0];
  view.redrawLink();
  await view.flush();
  assert.equal(view.links()[0], originalLinks[0]);
  assert.equal(view.badges()[0], existingBadge, "Jira can redraw anchor contents without losing its status icon");
  assert.equal(view.badges().length, 3);
  assert.equal(view.calls.length, 1, "Redrawing a link reuses the current status cache");

  view.setRows(["ZSTAC-4"]);
  await view.flush();
  assert.equal(view.calls.length, 2, "Pagination loads new keys");
  assert.equal(view.badges().length, 1, "Pagination removes obsolete icons");
  originalLinks[0].dispatch("mouseenter");
  assert.equal(view.root.hidden, true, "Pagination detaches the extension's old hover handlers");
  view.setError("Native Host 未连接");
  view.events.focus();
  await view.flush();
  assert.equal(view.badges()[0].dataset.state, "error");
  assert.match(view.badges()[0]["aria-label"], /未连接/);
  view.setError("");
  view.responses.set("ZSTAC-4", { exists: true, status: "active" });
  view.message({ type: "REFRESH_REQUIREMENT_LIST" });
  await view.flush();
  assert.match(view.badges()[0]["aria-label"], /需求记录：开发中/);
  const count = view.calls.length;
  view.hide(true);
  view.events.interval();
  await view.flush();
  assert.equal(view.calls.length, count, "Hidden tabs should not poll");
  view.hide(false);

  assert.equal(view.message({ type: "GET_REQUIREMENT_LIST_VISIBILITY" }).enabled, true);
  view.links()[0].dispatch("mouseenter");
  assert.equal(view.root.hidden, false);
  assert.equal(view.message({ type: "SET_REQUIREMENT_LIST_VISIBILITY", enabled: false }).enabled, false);
  assert.equal(view.root.hidden, true);
  assert.equal(view.badges()[0].hidden, true);
  view.links()[0].dispatch("mouseenter");
  assert.equal(view.root.hidden, true);
  view.events.interval();
  view.events.focus();
  view.message({ type: "REFRESH_REQUIREMENT_LIST" });
  view.inject();
  await view.flush();
  assert.equal(view.calls.length, count, "Disabled overlays do not poll or refresh on popup reinjection");
  assert.equal(view.message({ type: "GET_REQUIREMENT_LIST_VISIBILITY" }).enabled, false, "Reopening the popup preserves this document's choice");
  assert.equal(page().message({ type: "GET_REQUIREMENT_LIST_VISIBILITY" }).enabled, true, "Other tabs and newly loaded documents default to on");
  view.message({ type: "SET_REQUIREMENT_LIST_VISIBILITY", enabled: true });
  await view.flush();
  assert.equal(view.root.hidden, true, "Re-enabling waits for hover before showing the tooltip");
  assert.equal(view.badges()[0].hidden, false);
  assert.equal(view.calls.length, count + 1, "Re-enabling refreshes stale status immediately");

  const racing = page();
  racing.setDeferred(true);
  racing.setRows(["ZSTAC-10"]);
  await racing.flush();
  racing.setRows(["ZSTAC-11"]);
  await racing.flush();
  racing.pending.shift()();
  await racing.flush();
  assert.equal(racing.calls.length, 2, "Pagination during an in-flight read must fetch the new page");
  racing.message({ type: "SET_REQUIREMENT_LIST_VISIBILITY", enabled: false });
  racing.pending.shift()();
  await racing.flush();
  assert.equal(racing.root.hidden, true, "A late response must not restore hidden overlays");
  assert.ok(racing.badges().every((badge) => badge.hidden));
  racing.message({ type: "SET_REQUIREMENT_LIST_VISIBILITY", enabled: true });
  await racing.flush();
  racing.pending.shift()();
  await racing.flush();
  assert.equal(racing.badges().length, 1);
  racing.links()[0].dispatch("mouseenter");
  assert.equal(racing.root.children[1].textContent, "未记录");

  const many = page();
  many.setRows(Array.from({ length: 105 }, (_, index) => `ZSTAC-${index + 100}`));
  await many.flush();
  assert.deepEqual(many.calls.map((call) => call.issueKeys.length), [100, 5]);
  console.log("jira-list.behavior.test.js passed");
}

run().catch((error) => { console.error(error); process.exitCode = 1; });

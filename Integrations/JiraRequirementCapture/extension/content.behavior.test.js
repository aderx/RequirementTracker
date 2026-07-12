const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const contentSource = fs.readFileSync(path.join(__dirname, "content.js"), "utf8");

function element(text, extra = {}) {
  return {
    innerText: text,
    textContent: text,
    contains: () => false,
    querySelectorAll: () => [],
    ...extra
  };
}

function extractMR({ title, links = [], bodyText = "Open" }) {
  let listener;
  let response;
  const titleElement = element(title);
  const document = {
    title,
    body: element(bodyText),
    querySelector(selector) {
      if (selector === "h1" || selector.includes("issuable-title")) {
        return titleElement;
      }
      return null;
    },
    querySelectorAll(selector) {
      if (selector === "a[href]") {
        return links.map((href) => element(href, { href }));
      }
      if (selector === ".issuable-status-box") {
        return [element("Open")];
      }
      return [];
    }
  };
  const sandbox = {
    URL,
    window: {},
    document,
    location: {
      href: "http://gitlab.zstack.io/g/p/-/merge_requests/6732",
      hostname: "gitlab.zstack.io"
    },
    chrome: {
      runtime: {
        onMessage: {
          addListener(value) {
            listener = value;
          }
        }
      }
    }
  };

  vm.createContext(sandbox);
  vm.runInContext(contentSource, sandbox);
  listener(
    {
      type: "EXTRACT_REQUIREMENT_PAGE",
      settings: {
        jiraBaseURL: "http://jira.zstack.io/browse/",
        mrHosts: ["gitlab.zstack.io"]
      }
    },
    {},
    (value) => {
      response = value;
    }
  );

  assert.equal(response.ok, true);
  return response.result;
}

function testLinkedJiraWinsOverTitle() {
  const result = extractMR({
    title: "fix(vm): 示例 #ZSTAC-22222",
    links: ["http://jira.zstack.io/browse/ZSTAC-11111"]
  });

  assert.equal(result.payload.issueKey, "ZSTAC-11111");
  assert.equal(result.payload.jiraURL, "http://jira.zstack.io/browse/ZSTAC-11111");
}

function testHashJiraInMRTitleIsParsed() {
  const result = extractMR({
    title: "fix(vm): 移除 EmulatorPin 更多操作入口 #ZSTAC-86658"
  });

  assert.equal(result.payload.issueKey, "ZSTAC-86658");
  assert.equal(result.payload.jiraURL, "http://jira.zstack.io/browse/ZSTAC-86658");
}

function testUnprefixedJiraTextDoesNotMatchTitleFallback() {
  const result = extractMR({
    title: "fix(vm): unrelated ZSTAC-99999"
  });

  assert.equal(result.payload.issueKey, undefined);
  assert.equal(result.payload.jiraURL, undefined);
}

testLinkedJiraWinsOverTitle();
testHashJiraInMRTitleIsParsed();
testUnprefixedJiraTextDoesNotMatchTitleFallback();
console.log("content.behavior.test.js passed");

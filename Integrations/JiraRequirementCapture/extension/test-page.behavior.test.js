const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const html = fs.readFileSync(path.join(__dirname, "test.html"), "utf8");
const script = fs.readFileSync(path.join(__dirname, "test.js"), "utf8");

function testPageOnlyContainsRealStateControlsAndBindingInformation() {
  assert.match(html, /插件图标和弹出的详情卡片会同步切换/);
  assert.match(html, /id="stateButtons"/);
  assert.match(html, /<h2>绑定信息<\/h2>/);
  assert.doesNotMatch(html, /<canvas|iconPreview|preview-card|Jira Requirement Capture/);
  assert.doesNotMatch(script, /BadgeIconRenderer|drawPreview|currentStateText/);
}

function testStateControlsDriveTheBackgroundToolbarPath() {
  assert.match(script, /type:\s*"APPLY_TEST_PAGE_STATE"/);
  assert.match(script, /url:\s*window\.location\.href/);
  assert.doesNotMatch(script, /type:\s*"SET_TEST_BADGE_STATE"/);
}

function testChromeRuntimeErrorsArePresentedInChinese() {
  assert.match(script, /请在扩展管理页重新加载插件后重试/);
  assert.match(script, /插件后台未响应，请重试/);
  assert.doesNotMatch(script, /applyResult\.textContent\s*=\s*error\.message/);
}

testPageOnlyContainsRealStateControlsAndBindingInformation();
testStateControlsDriveTheBackgroundToolbarPath();
testChromeRuntimeErrorsArePresentedInChinese();
console.log("test-page.behavior.test.js passed");

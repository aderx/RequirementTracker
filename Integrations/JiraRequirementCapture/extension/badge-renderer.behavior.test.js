const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const rendererSource = fs.readFileSync(path.join(__dirname, "badge-renderer.js"), "utf8");

class ContextStub {
  constructor() {
    this.operations = [];
    this.fillStyle = "";
    this.font = "";
    this.textAlign = "";
    this.textBaseline = "";
  }

  clearRect(...arguments_) { this.operations.push(["clearRect", ...arguments_]); }
  beginPath() { this.operations.push(["beginPath"]); }
  roundRect(...arguments_) { this.operations.push(["roundRect", ...arguments_]); }
  fill() { this.operations.push(["fill", this.fillStyle]); }

  measureText(text) {
    this.operations.push(["measureText", text]);
    return {
      actualBoundingBoxAscent: 60,
      actualBoundingBoxDescent: 12
    };
  }

  fillText(text, x, y) {
    this.operations.push([
      "fillText",
      text,
      x,
      y,
      this.fillStyle,
      this.font,
      this.textAlign,
      this.textBaseline
    ]);
  }
}

function createRenderer() {
  const sandbox = { console };

  vm.createContext(sandbox);
  vm.runInContext(rendererSource, sandbox);
  return sandbox.BadgeIconRenderer;
}

function drawPreview(renderer, state) {
  const context = new ContextStub();
  const canvas = {
    width: 96,
    height: 96,
    getContext() {
      return context;
    }
  };
  renderer.drawBadgePreview(canvas, state);
  return context.operations;
}

function testStylesMatchTheVerifiedNativeBadgeSet() {
  const renderer = createRenderer();
  const stateTokens = Object.fromEntries(
    Object.entries(renderer.styles).map(([state, style]) => [
      state,
      { text: style.text, color: style.color }
    ])
  );

  assert.deepEqual(stateTokens, {
    addable: { text: "+", color: "#FF9500" },
    recorded: { text: "↻", color: "#1F9D54" },
    done: { text: "✓", color: "#1570EF" },
    tested: { text: "\u2714\uFE0E", color: "#7F56D9" },
    merged: { text: "⇧", color: "#1F9D54" },
    paused: { text: "Ⅱ", color: "#F59E0B" },
    stopped: { text: "■", color: "#D92D43" }
  });
}

function testPopupPreviewUsesTheSameSymbolColorAndCenteredGeometry() {
  const renderer = createRenderer();
  for (const [state, style] of Object.entries(renderer.styles)) {
    const operations = drawPreview(renderer, state);
    assert.deepEqual(
      operations.find(([name]) => name === "roundRect"),
      ["roundRect", 0, 0, 96, 96, 24]
    );
    assert.deepEqual(
      operations.find(([name]) => name === "fill"),
      ["fill", style.color]
    );

    const text = operations.find(([name]) => name === "fillText");
    assert.equal(text[1], style.text);
    assert.equal(text[2], 48);
    assert.equal(text[3], 72);
    assert.equal(text[4], "#FFFFFF");
    assert.equal(text[6], "center");
    assert.equal(text[7], "alphabetic");
  }

  const addableFont = drawPreview(renderer, "addable")
    .find(([name]) => name === "fillText")[5];
  const stoppedFont = drawPreview(renderer, "stopped")
    .find(([name]) => name === "fillText")[5];
  const addableFontSize = Number.parseFloat(addableFont.match(/800 ([\d.]+)px/)[1]);
  const stoppedFontSize = Number.parseFloat(stoppedFont.match(/800 ([\d.]+)px/)[1]);
  assert.ok(addableFontSize > stoppedFontSize);
}

function run() {
  testStylesMatchTheVerifiedNativeBadgeSet();
  testPopupPreviewUsesTheSameSymbolColorAndCenteredGeometry();
}

Promise.resolve().then(() => {
  run();
  console.log("badge-renderer.behavior.test.js passed");
}).catch((error) => {
  console.error(error);
  process.exitCode = 1;
});

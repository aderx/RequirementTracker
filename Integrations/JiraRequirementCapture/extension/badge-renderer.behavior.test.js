const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

class PathStub {
  constructor(data) { this.operations = data ? [["path", data]] : []; }
  arc(...values) { this.operations.push(["arc", ...values]); }
  roundRect(...values) { this.operations.push(["roundRect", ...values]); }
}

function createCanvas() {
  const operations = [];
  const context = {
    clearRect(...values) { operations.push(["clear", ...values]); },
    beginPath() {}, roundRect() {}, save() {}, restore() {}, translate() {}, scale() {},
    createLinearGradient() { return { addColorStop() {} }; },
    drawImage(...values) { operations.push(["logo", ...values]); },
    fill(shape) { operations.push(["fill", this.fillStyle, shape?.operations]); },
    stroke(shape) { operations.push(["stroke", this.strokeStyle, shape?.operations]); },
    fillText() { throw new Error("Status icons must not depend on OS font/emoji rendering"); }
  };
  return { width: 96, height: 96, getContext: () => context, operations };
}

const sandbox = { Path2D: PathStub };
vm.createContext(sandbox);
vm.runInContext(fs.readFileSync(path.join(__dirname, "badge-renderer.js"), "utf8"), sandbox);
const renderer = sandbox.BadgeIconRenderer;
const fingerprints = new Set();
for (const state of ["addable", "recorded", "done", "tested", "merged", "paused", "stopped"]) {
  const canvas = createCanvas();
  renderer.drawBadgePreview(canvas, state);
  const shapes = canvas.operations.filter(([operation, , shape]) => operation === "stroke" && shape);
  assert.ok(shapes.length > 0, `${state}: missing symbol`);
  fingerprints.add(JSON.stringify(shapes));
  for (const size of [16, 32, 48, 128]) {
    const png = fs.readFileSync(path.join(__dirname, `icons/status/${state}-${size}.png`));
    assert.equal(png.subarray(0, 8).toString("hex"), "89504e470d0a1a0a");
    assert.equal(png.readUInt32BE(16), size);
    assert.equal(png.readUInt32BE(20), size);
  }
}
assert.equal(fingerprints.size, 7, "Every status must have a distinct shape, independent of color");
const empty = createCanvas();
renderer.drawBadgePreview(empty, "unsupported");
assert.deepEqual(empty.operations, [["clear", 0, 0, 96, 96]]);
console.log("badge-renderer.behavior.test.js passed");

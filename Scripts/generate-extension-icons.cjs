// 使用已有的 Node + Playwright 环境生成资源，不启动服务或使用用户的 Chrome 资料。
// NODE_PATH=<existing-node-modules> node Scripts/generate-extension-icons.cjs
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { chromium } = require("playwright");
const extension = path.resolve(__dirname, "../Integrations/JiraRequirementCapture/extension");

async function run() {
  const browser = await chromium.launch({ headless: true, channel: "chrome" });
  try {
    const page = await browser.newPage();
    await page.addScriptTag({ content: fs.readFileSync(path.join(extension, "badge-renderer.js"), "utf8") });
    const images = await page.evaluate(() => {
      const outputs = [];
      for (const state of Object.keys(BadgeIconRenderer.styles)) {
        // 固定 32px 设计以 4 倍采样绘制一次，各尺寸只缩放这张完整母版。
        const master = document.createElement("canvas");
        master.width = master.height = 32 * 4;
        BadgeIconRenderer.drawBadgePreview(master, state);
        const background = document.createElement("canvas");
        background.width = background.height = master.width;
        const backgroundContext = background.getContext("2d");
        const backgroundGradient = backgroundContext.createLinearGradient(0, 0, master.width, master.height);
        BadgeIconRenderer.styles[state].gradient.forEach((color, index) => backgroundGradient.addColorStop([0, 0.54, 1][index], color));
        backgroundContext.fillStyle = backgroundGradient;
        backgroundContext.beginPath();
        backgroundContext.roundRect(0, 0, master.width, master.height, master.width * 0.25);
        backgroundContext.fill();
        for (const size of [16, 32, 48, 128]) {
          const canvas = document.createElement("canvas");
          canvas.width = canvas.height = size;
          const context = canvas.getContext("2d");
          context.imageSmoothingEnabled = true;
          context.imageSmoothingQuality = "high";
          context.drawImage(master, 0, 0, size, size);
          const pixels = context.getImageData(0, 0, size, size).data;
          const at = (x, y) => [...pixels.slice((y * size + x) * 4, (y * size + x) * 4 + 4)];
          // 左右边缘中点不与任何状态图形重叠，避免盾牌描边干扰背景采样。
          const left = at(0, Math.floor(size / 2));
          const right = at(size - 1, Math.floor(size / 2));
          if (left[3] !== 255 || right[3] !== 255 || at(0, 0)[3] !== 0) throw new Error(`${state}/${size}: incorrect background bounds`);
          if (left.slice(0, 3).reduce((a, b) => a + b) <= right.slice(0, 3).reduce((a, b) => a + b)) throw new Error(`${state}/${size}: gradient is missing or reversed`);
          const baseline = document.createElement("canvas");
          baseline.width = baseline.height = size;
          const baselineContext = baseline.getContext("2d");
          baselineContext.imageSmoothingQuality = "high";
          baselineContext.drawImage(background, 0, 0, size, size);
          const baselinePixels = baselineContext.getImageData(0, 0, size, size).data;
          // 小图细线与底色混合，对比无图形背景验证笔画存在，不要求纯白像素。
          const hasSymbol = Array.from({length:size * size}, (_, p) => p * 4).some(p =>
            pixels[p + 3] > 245 && pixels[p] + pixels[p + 1] + pixels[p + 2] - baselinePixels[p] - baselinePixels[p + 1] - baselinePixels[p + 2] > 50);
          if (!hasSymbol) throw new Error(`${state}/${size}: white symbol is missing`);
          if (state === "stopped") {
            const whiteWidth = Array.from({length:size}, (_, x) => at(x, Math.floor(size / 2)))
              .filter(([r, g, b]) => r > 245 && g > 245 && b > 245).length;
            // 用户确认图为 64px 背景、30px 白色方块；允许小图抗锯齿的两像素误差。
            if (Math.abs(whiteWidth - size * 30 / 64) > 2) throw new Error(`${state}/${size}: symbol-to-background ratio changed (${whiteWidth}/${size})`);
          }
          outputs.push({ state, size, data: canvas.toDataURL("image/png").split(",")[1] });
        }
      }
      return outputs;
    });
    assert.equal(images.length, 28);
    const directory = path.join(extension, "icons/status");
    fs.mkdirSync(directory, { recursive: true });
    for (const { state, size, data } of images) fs.writeFileSync(path.join(directory, `${state}-${size}.png`), Buffer.from(data, "base64"));
    console.log("Generated 28 gradient status icons; real Canvas background, gradient and symbol checks passed.");
  } finally {
    await browser.close();
  }
}
run().catch((error) => { console.error(error); process.exitCode = 1; });

(function exposeBadgeIconRenderer(global) {
  const styles = Object.freeze({
    addable: { label: "可添加", text: "+", color: "#D97706", gradient: ["#FFCF78", "#E99417", "#AD5800"] },
    recorded: { label: "已记录", text: "↻", color: "#1F9D54", gradient: ["#70D8AA", "#21A568", "#08683D"] },
    done: { label: "开发完成", text: "✓", color: "#149FB4", gradient: ["#72E0EA", "#149FB4", "#086276"] },
    tested: { label: "已自测", text: "\u2714\uFE0E", color: "#8055D9", gradient: ["#BD9BFF", "#8653DE", "#51249F"] },
    merged: { label: "已合并", text: "⇧", color: "#168454", gradient: ["#69CDA1", "#168858", "#065333"] },
    paused: { label: "已暂停", text: "Ⅱ", color: "#D97706", gradient: ["#FFCF78", "#E99417", "#AD5800"] },
    stopped: { label: "已停止", text: "■", color: "#D92D43", gradient: ["#FF94A5", "#DE3656", "#9C1535"] }
  });

  // 基于 Lucide 路径调整笔画和填充，只内置用到的图形，无运行时图标库依赖。
  // 来源及许可见 icons/LUCIDE-LICENSE.txt。
  const symbols = {
    addable: [["path", { d: "M5 12h14" }], ["path", { d: "M12 5v14" }]],
    recorded: [["path", { d: "M17 3a2 2 0 0 1 2 2v15a1 1 0 0 1-1.496.868l-4.512-2.578a2 2 0 0 0-1.984 0l-4.512 2.578A1 1 0 0 1 5 20V5a2 2 0 0 1 2-2z" }]],
    done: [["path", { d: "M20 6 9 17l-5-5" }]],
    tested: [
      ["path", {
        d: "M20 13c0 5-3.5 7.5-7.66 8.95a1 1 0 0 1-.67-.01C7.5 20.5 4 18 4 13V6a1 1 0 0 1 1-1c2 0 4.5-1.2 6.24-2.72a1.17 1.17 0 0 1 1.52 0C14.51 3.81 17 5 19 5a1 1 0 0 1 1 1z",
        cutout: "M7.15 12.85Q6.3 12 7.15 11.15Q8 10.3 8.85 11.15L10.5 12.8L14.15 9.15Q15 8.3 15.85 9.15Q16.7 10 15.85 10.85L11.35 15.35Q10.5 16.2 9.65 15.35Z"
      }]
    ],
    merged: [
      ["circle", { cx: 18, cy: 18, r: 3 }],
      ["circle", { cx: 6, cy: 6, r: 3 }],
      ["path", { d: "M6 21V9a9 9 0 0 0 9 9" }]
    ],
    paused: [["rect", { x: 14, y: 3, width: 5, height: 18, rx: 1 }], ["rect", { x: 5, y: 3, width: 5, height: 18, rx: 1 }]],
    stopped: [["rect", { x: 3, y: 3, width: 18, height: 18, rx: 2 }]]
  };

  function drawSymbol(context, state, x, y, size) {
    context.save();
    context.translate(x, y);
    // 保留素材的完整 24px 画布；裁掉素材留白会改变图形相对背景的比例。
    context.scale(size / 24, size / 24);
    context.lineCap = "round";
    context.lineJoin = "round";
    for (const [kind, attributes] of symbols[state]) {
      const path = new Path2D(kind === "path" ? attributes.d : undefined);
      if (kind === "circle") {
        path.arc(attributes.cx, attributes.cy, attributes.r, 0, Math.PI * 2);
      } else if (kind === "rect") {
        path.roundRect(attributes.x, attributes.y, attributes.width, attributes.height, attributes.rx);
      }
      const solid = ["recorded", "tested", "paused", "stopped"].includes(state) || kind === "circle";
      context.fillStyle = "#FFFFFF";
      context.strokeStyle = "#FFFFFF";
      context.lineWidth = solid ? 1.25 : ["addable", "done"].includes(state) ? 4.5 : 2.5;
      if (attributes.cutout) {
        // 镂空保留背景原有渐变，避免用纯色盖住内部勾号。
        context.fill(new Path2D(`${attributes.d} ${attributes.cutout}`), "evenodd");
      } else if (solid) {
        context.fill(path);
      }
      context.stroke(path);
    }
    context.restore();
  }

  function drawBadge(context, state, x, y, size) {
    context.beginPath();
    context.roundRect(x, y, size, size, size * 0.25);
    const gradient = context.createLinearGradient(x, y, x + size, y + size);
    const [top, middle, bottom] = styles[state].gradient;
    gradient.addColorStop(0, top);
    gradient.addColorStop(0.54, middle);
    gradient.addColorStop(1, bottom);
    context.fillStyle = gradient;
    context.fill();
    // 对齐确认图：停止方块的可见宽度约占背景 47%，而不是铺满背景。
    const symbolSize = size * 0.6;
    const inset = (size - symbolSize) / 2;
    drawSymbol(context, state, x + inset, y + inset, symbolSize);
  }

  function drawBadgePreview(canvas, state) {
    const context = canvas.getContext("2d");
    const size = Math.min(canvas.width, canvas.height);
    context.clearRect(0, 0, size, size);
    if (styles[state]) {
      context.save();
      context.scale(size / 32, size / 32);
      drawBadge(context, state, 0, 0, 32);
      context.restore();
    }
  }

  global.BadgeIconRenderer = Object.freeze({
    styles,
    drawBadgePreview
  });
})(globalThis);

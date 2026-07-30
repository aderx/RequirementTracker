(function exposeBadgeIconRenderer(global) {
  const styles = Object.freeze({
    addable: { label: "可添加", text: "+", color: "#FF9500" },
    recorded: { label: "已记录", text: "↻", color: "#1F9D54" },
    done: { label: "开发完成", text: "✓", color: "#1570EF" },
    // 强制重勾使用文本字形，避免 macOS 绕过角标的白色文字色。
    tested: { label: "已自测", text: "\u2714\uFE0E", color: "#7F56D9" },
    merged: { label: "已合并", text: "⇧", color: "#1F9D54" },
    paused: { label: "已暂停", text: "Ⅱ", color: "#F59E0B" },
    stopped: { label: "已停止", text: "■", color: "#D92D43" }
  });

  function drawBadgePreview(canvas, state) {
    const context = canvas.getContext("2d");
    const size = Math.min(canvas.width, canvas.height);
    context.clearRect(0, 0, size, size);
    const style = styles[state];
    if (!style) {
      return;
    }

    context.beginPath();
    context.roundRect(0, 0, size, size, size * 0.25);
    context.fillStyle = style.color;
    context.fill();

    context.fillStyle = "#FFFFFF";
    context.textAlign = "center";
    context.textBaseline = "alphabetic";
    context.font = `800 ${previewFontSize(state, size)}px -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif`;

    const metrics = context.measureText(style.text);
    const ascent = Number(metrics.actualBoundingBoxAscent || 0);
    const descent = Number(metrics.actualBoundingBoxDescent || 0);
    const centeredBaseline = size / 2 + (ascent - descent) / 2;
    context.fillText(style.text, size / 2, centeredBaseline);
  }

  function previewFontSize(state, size) {
    if (state === "addable") {
      return size * 0.72;
    }
    if (state === "recorded" || state === "merged") {
      return size * 0.64;
    }
    if (state === "paused") {
      return size * 0.58;
    }
    return size * 0.62;
  }

  global.BadgeIconRenderer = Object.freeze({
    styles,
    drawBadgePreview
  });
})(globalThis);

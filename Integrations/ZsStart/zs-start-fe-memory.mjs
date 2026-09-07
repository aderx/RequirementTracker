import { mkdirSync, renameSync, unlinkSync, writeFileSync } from "node:fs";
import { basename, dirname, join } from "node:path";
import { spawnSync } from "node:child_process";

const STATE_ENV_KEY = "ZS_START_FRONTEND_STATE_PATH";
const AUTO_PREPARE_ENV_KEY = "ZS_START_FRONTEND_AUTO_PREPARE";
const PREPARE_SCRIPT_ENV_KEY = "ZS_START_FRONTEND_PREPARE_SCRIPT";
const PREPARE_COMMAND = "__prepare-frontend";
const ANSI_SEQUENCE = /\u001B\[[0-?]*[ -/]*[@-~]/gu;
const APP_NAME = /^[A-Za-z0-9][A-Za-z0-9._-]*$/u;
const MAX_CAPTURE_LENGTH = 128 * 1024;

function selectedProduct(argv) {
  const productIndex = argv.indexOf("--product");
  const product = productIndex >= 0 ? argv[productIndex + 1] : "cloud";
  return product === "zns" ? "zns" : "cloud";
}

function extractStartSelection(output) {
  const normalizedOutput = output.replace(ANSI_SEQUENCE, "");
  const lines = normalizedOutput.split(/\r?\n/u);
  let startIndex = -1;
  for (let index = 0; index < lines.length; index += 1) {
    if (lines[index].includes("Starting") && lines[index].includes("service(s)")) {
      startIndex = index;
    }
  }
  const summaryLines = startIndex >= 0 ? lines.slice(startIndex) : lines;
  const separatorCount = summaryLines.filter((line) => line.includes("───")).length;
  if (separatorCount < 2 && !normalizedOutput.includes("All services started!")) {
    return null;
  }

  const apps = [];
  const seenApps = new Set();
  let startProxy = false;
  for (const rawLine of summaryLines) {
    if (!rawLine.includes("✓")) {
      continue;
    }
    if (rawLine.includes("MF Hub Proxy")) {
      startProxy = true;
      continue;
    }
    const match = rawLine.match(/✓\s+([^\s:]+)/u);
    const app = match?.[1];
    if (app && APP_NAME.test(app) && !seenApps.has(app)) {
      seenApps.add(app);
      apps.push(app);
    }
  }

  return apps.length > 0 ? { apps, startProxy } : null;
}

function prepareSelection(product, apps) {
  if (process.env[AUTO_PREPARE_ENV_KEY] !== "1") {
    return;
  }
  const prepareScript = process.env[PREPARE_SCRIPT_ENV_KEY];
  if (!prepareScript) {
    throw new Error("zs-start 未提供前端依赖准备脚本");
  }
  const result = spawnSync(
    "/usr/bin/python3",
    [
      prepareScript,
      PREPARE_COMMAND,
      "--product",
      product,
      "--apps",
      apps.join(","),
    ],
    {
      cwd: process.cwd(),
      env: process.env,
      stdio: "inherit",
    },
  );
  if (result.error) {
    throw result.error;
  }
  if (result.status !== 0) {
    throw new Error(`前端依赖自动准备失败（退出码 ${result.status ?? "未知"}）`);
  }
}

function writeState(statePath, payload) {
  const directory = dirname(statePath);
  const temporaryPath = join(
    directory,
    `.${basename(statePath)}.${process.pid}.${Date.now()}.tmp`,
  );
  try {
    mkdirSync(directory, { recursive: true, mode: 0o700 });
    writeFileSync(temporaryPath, JSON.stringify(payload), {
      encoding: "utf8",
      flag: "wx",
      mode: 0o600,
    });
    renameSync(temporaryPath, statePath);
  } catch {
    try {
      unlinkSync(temporaryPath);
    } catch {
      // 启动记忆失败不能影响原本的前端启动流程。
    }
  }
}

const statePath = process.env[STATE_ENV_KEY];
if (statePath) {
  const originalLog = console.log.bind(console);
  let capturedOutput = "";
  let hasRemembered = false;
  let hasPrepared = false;

  console.log = function logAndRemember(...values) {
    const text = `${values.map((value) => String(value)).join(" ")}\n`;
    capturedOutput = `${capturedOutput}${text}`.slice(-MAX_CAPTURE_LENGTH);
    originalLog(...values);

    if (!hasRemembered || !hasPrepared) {
      const selection = extractStartSelection(capturedOutput);
      if (selection) {
        const product = selectedProduct(process.argv);
        if (!hasPrepared) {
          prepareSelection(product, selection.apps);
          hasPrepared = true;
        }
        if (!hasRemembered) {
          hasRemembered = true;
          writeState(statePath, {
            version: 1,
            product,
            apps: selection.apps,
            startProxy: selection.startProxy,
          });
        }
      }
    }
  };
}

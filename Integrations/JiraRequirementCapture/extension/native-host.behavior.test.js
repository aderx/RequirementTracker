const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const repoRoot = path.resolve(__dirname, "../../..");
const hostBinary = process.env.REQUIREMENT_TRACKER_NATIVE_HOST
  || path.join(repoRoot, ".build", "debug", "JiraRequirementNativeHost");

function sendNativeMessage(dataFile, message) {
  const body = Buffer.from(JSON.stringify(message), "utf8");
  const input = Buffer.allocUnsafe(body.length + 4);
  input.writeUInt32LE(body.length, 0);
  body.copy(input, 4);

  const result = spawnSync(hostBinary, [], {
    input,
    env: {
      ...process.env,
      REQUIREMENT_TRACKER_DATA_FILE: dataFile
    },
    maxBuffer: 1024 * 1024
  });

  assert.equal(result.status, 0, result.stderr.toString("utf8"));
  assert.ok(result.stdout.length >= 4, "Native Host should return a framed response");
  const length = result.stdout.readUInt32LE(0);
  return JSON.parse(result.stdout.subarray(4, 4 + length).toString("utf8"));
}

function readRecords(dataFile) {
  return JSON.parse(fs.readFileSync(dataFile, "utf8"));
}

function run() {
  assert.ok(fs.existsSync(hostBinary), "Build JiraRequirementNativeHost before running this check");

  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "requirement-native-host-"));
  const dataFile = path.join(directory, "requirements.json");
  const issueKey = "ZSTAC-12345";
  const jiraURL = "http://jira.zstack.io/browse/ZSTAC-12345";
  const firstMR = "http://gitlab.zstack.io/g/p/-/merge_requests/1";
  const secondMR = "http://gitlab.zstack.io/g/p/-/merge_requests/2";

  try {
    const settings = sendNativeMessage(dataFile, {
      type: "getPluginSettings",
      payload: {}
    });
    assert.equal(settings.ok, true);
    assert.equal(settings.protocolVersion, 3);

    const rejectedJiraStatus = sendNativeMessage(dataFile, {
      type: "upsertJiraRequirement",
      payload: { issueKey, jiraURL, targetStatus: "tested" }
    });
    assert.equal(rejectedJiraStatus.ok, false);
    assert.match(rejectedJiraStatus.error, /Jira.*已自测|tested/i);

    const created = sendNativeMessage(dataFile, {
      type: "upsertJiraRequirement",
      payload: { issueKey, jiraURL }
    });
    assert.equal(created.ok, true);

    const savedWithoutStatus = sendNativeMessage(dataFile, {
      type: "attachMergeRequest",
      payload: { issueKey, jiraURL, mrURL: firstMR, mrState: "open", targetStatus: "" }
    });
    assert.equal(savedWithoutStatus.ok, true);
    assert.equal(savedWithoutStatus.statusUpdated, false);
    let record = readRecords(dataFile)[0];
    assert.equal(record.mrURL, firstMR);
    assert.equal(record.isDone, false);
    assert.equal(record.isTested, false);
    assert.equal(record.isMerged, false);
    assert.equal(record.mrHistory, undefined);
    assert.equal(record.mrTrackingStatus, "created");

    record.mrTrackingStatus = "mergeRequested";
    record.isMRMergeMonitoringEnabled = true;
    const updatedAtBeforeTrackedMerge = record.updatedAt;
    fs.writeFileSync(dataFile, JSON.stringify([record]));

    const monitors = sendNativeMessage(dataFile, {
      type: "listMRMergeMonitors",
      payload: {}
    });
    assert.equal(monitors.ok, true);
    assert.deepEqual(monitors.monitors, [{ issueKey, mrURL: firstMR }]);

    const trackedMerge = sendNativeMessage(dataFile, {
      type: "markMRMergeMonitorMerged",
      payload: { issueKey, mrURL: firstMR }
    });
    assert.equal(trackedMerge.ok, true);
    assert.equal(trackedMerge.action, "mrMerged");
    record = readRecords(dataFile)[0];
    assert.equal(record.mrTrackingStatus, "merged");
    assert.equal(record.mrMergeReminderPending, true);
    assert.equal(record.isMRMergeMonitoringEnabled, undefined);
    assert.equal(record.isDone, false);
    assert.equal(record.isTested, false);
    assert.equal(record.isMerged, false);
    assert.equal(record.updatedAt, updatedAtBeforeTrackedMerge);

    const tested = sendNativeMessage(dataFile, {
      type: "attachMergeRequest",
      payload: { issueKey, jiraURL, mrURL: firstMR, mrState: "open", targetStatus: "tested" }
    });
    assert.equal(tested.ok, true);
    assert.equal(tested.statusUpdated, true);
    record = readRecords(dataFile)[0];
    assert.equal(record.isTested, true);
    assert.deepEqual(
      record.statusHistory.map((event) => event.status),
      ["pending", "active", "done", "tested"]
    );

    const merged = sendNativeMessage(dataFile, {
      type: "attachMergeRequest",
      payload: { issueKey, jiraURL, mrURL: secondMR, mrState: "merged", targetStatus: "merged" }
    });
    assert.equal(merged.ok, true);
    assert.equal(merged.action, "appended");
    record = readRecords(dataFile)[0];
    assert.equal(record.mrURL, secondMR);
    assert.deepEqual(record.mrHistory, [firstMR]);
    assert.equal(record.isMerged, true);
    assert.equal(record.mrTrackingStatus, undefined);
    assert.equal(record.mrMergeReminderPending, undefined);

    const historicalInspection = sendNativeMessage(dataFile, {
      type: "inspectByURL",
      payload: { url: firstMR }
    });
    assert.equal(historicalInspection.ok, true);
    assert.equal(historicalInspection.exists, true);
    assert.equal(historicalInspection.status, "merged");

    record.stage = "paused";
    record.pauseReason = "等待后端接口";
    record.isDone = false;
    record.isTested = false;
    record.isMerged = false;
    fs.writeFileSync(dataFile, JSON.stringify([record]));

    const pausedInspection = sendNativeMessage(dataFile, {
      type: "inspectRequirement",
      payload: { issueKey, jiraURL }
    });
    assert.equal(pausedInspection.ok, true);
    assert.equal(pausedInspection.status, "paused");
    assert.equal(pausedInspection.pauseReason, "等待后端接口");
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
}

try {
  run();
  console.log("native-host.behavior.test.js passed");
} catch (error) {
  console.error(error);
  process.exitCode = 1;
}

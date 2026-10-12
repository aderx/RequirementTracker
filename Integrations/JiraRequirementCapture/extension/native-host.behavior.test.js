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
  const db = dataFile.replace(/\.json$/, ".sqlite");
  const result = spawnSync("python3", ["-c", "import sqlite3,json,sys; c=sqlite3.connect(sys.argv[1]); print(json.dumps([json.loads(r[0]) for r in c.execute('SELECT payload FROM requirements ORDER BY position,id')]))", db], {encoding: "utf8"});
  assert.equal(result.status, 0, result.stderr);
  return JSON.parse(result.stdout);
}

// Each fixture starts a fresh migration; subsequent Native Host calls share SQLite.
function writeFixture(dataFile, records) {
  fs.writeFileSync(dataFile, JSON.stringify(records));
  const db = dataFile.replace(/\.json$/, ".sqlite");
  for (const suffix of ["", "-wal", "-shm"]) fs.rmSync(db + suffix, {force: true});
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

    const epic = {key: "ZSTAC-87912", name: "健康检查 Buglist", url: "http://jira.zstack.io/browse/ZSTAC-87912"};
    assert.equal(sendNativeMessage(dataFile, {type: "upsertJiraRequirement", payload: {issueKey, jiraURL, epic}}).ok, true);
    assert.equal(readRecords(dataFile)[0].epicKey, epic.key);
    assert.equal(readRecords(dataFile)[0].epicName, epic.name);
    assert.equal(readRecords(dataFile)[0].epicURL, epic.url);
    assert.ok(readRecords(dataFile)[0].epicCapturedAt);
    sendNativeMessage(dataFile, {type: "upsertJiraRequirement", payload: {issueKey, jiraURL}});
    assert.equal(readRecords(dataFile)[0].epicKey, epic.key, "Unrecognized Epic fields must preserve saved binding");
    sendNativeMessage(dataFile, {type: "upsertJiraRequirement", payload: {issueKey, jiraURL, epic: null}});
    assert.equal(readRecords(dataFile)[0].epicKey, undefined);
    assert.equal(readRecords(dataFile)[0].epicName, undefined);
    assert.equal(readRecords(dataFile)[0].epicURL, undefined);
    assert.ok(readRecords(dataFile)[0].epicCapturedAt, "Known empty is distinct from never captured");
    sendNativeMessage(dataFile, {type: "upsertJiraRequirement", payload: {issueKey, jiraURL, epic}});

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

    const savedData = JSON.stringify(readRecords(dataFile));
    const savedBinding = sendNativeMessage(dataFile, {
      type: "inspectByURL",
      payload: { mrURL: `${firstMR}?view=parallel#note_10` }
    });
    assert.equal(savedBinding.ok, true);
    assert.equal(savedBinding.exists, true);
    assert.equal(savedBinding.issueKey, issueKey);
    assert.equal(savedBinding.jiraURL, jiraURL);
    assert.equal(JSON.stringify(readRecords(dataFile)), savedData);

    const unboundMR = sendNativeMessage(dataFile, {
      type: "inspectByURL",
      payload: { mrURL: `http://gitlab.zstack.io/g/${issueKey}/-/merge_requests/999` }
    });
    assert.equal(unboundMR.ok, true);
    assert.equal(unboundMR.exists, false);
    assert.equal(unboundMR.issueKey, "");

    record.mrTrackingStatus = "mergeRequested";
    record.isMRMergeMonitoringEnabled = true;
    const updatedAtBeforeTrackedMerge = record.updatedAt;
    writeFixture(dataFile, [record]);

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

    const historicalBinding = sendNativeMessage(dataFile, {
      type: "inspectByURL",
      payload: { mrURL: firstMR }
    });
    assert.equal(historicalBinding.exists, true);
    assert.equal(historicalBinding.issueKey, issueKey);
    assert.equal(historicalBinding.jiraURL, jiraURL);

    const beforeInfoUpdate = JSON.stringify(record);
    const updatedOnly = sendNativeMessage(dataFile, {
      type: "upsertJiraRequirement",
      payload: { issueKey, title: "重新打开后的标题", targetStatus: "" }
    });
    assert.equal(updatedOnly.statusUpdated, false);
    assert.equal(readRecords(dataFile)[0].isMerged, true);

    for (const targetStatus of ["pending", "active"]) {
      record = JSON.parse(beforeInfoUpdate);
      writeFixture(dataFile, [record]);
      const reopened = sendNativeMessage(dataFile, {
        type: "upsertJiraRequirement",
        payload: { issueKey, title: "重新打开后的标题", targetStatus, reopen: true }
      });
      assert.equal(reopened.ok, true);
      assert.equal(reopened.statusUpdated, true);
      const reopenedRecord = readRecords(dataFile)[0];
      assert.equal(reopenedRecord.stage, targetStatus);
      assert.equal(reopenedRecord.title, "重新打开后的标题");
      assert.equal(reopenedRecord.isDone, false);
      assert.equal(reopenedRecord.isTested, false);
      assert.equal(reopenedRecord.isMerged, false);
      assert.equal(reopenedRecord.completedAt, undefined);
      assert.equal(reopenedRecord.mrURL, secondMR);
      assert.deepEqual(reopenedRecord.mrHistory, [firstMR]);
      assert.equal(reopenedRecord.mrTrackingStatus, undefined);
      assert.equal(reopenedRecord.mrMergeReminderPending, undefined);
      assert.deepEqual(reopenedRecord.statusHistory.slice(0, -1), record.statusHistory);
      assert.equal(reopenedRecord.statusHistory.at(-1).status, targetStatus);

      const repeat = sendNativeMessage(dataFile, {
        type: "upsertJiraRequirement",
        payload: { issueKey, targetStatus, reopen: true }
      });
      assert.equal(repeat.statusUpdated, false);
      assert.deepEqual(readRecords(dataFile)[0].statusHistory, reopenedRecord.statusHistory);
    }

    const rejectedReopen = sendNativeMessage(dataFile, {
      type: "upsertJiraRequirement",
      payload: { issueKey, targetStatus: "done", reopen: true }
    });
    assert.equal(rejectedReopen.ok, false);

    record.stage = "paused";
    record.pauseReason = "等待后端接口";
    record.isDone = false;
    record.isTested = false;
    record.isMerged = false;
    writeFixture(dataFile, [record]);

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

function testAutomaticStatusPersistence() {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "requirement-auto-mr-"));
  const dataFile = path.join(directory, "requirements.json");
  const issueKey = "ZSTAC-23456";
  const mrURL = "http://gitlab.zstack.io/g/p/-/merge_requests/100";
  const sync = (extra = {}) => sendNativeMessage(dataFile, { type: "syncMRStatus", payload: { issueKey, mrURL, mrState: "open", ...extra } });
  try {
    assert.equal(sync({ allowInitialBinding: true }).action, "ignored", "Never create requirements automatically");
    sendNativeMessage(dataFile, { type: "upsertJiraRequirement", payload: { issueKey } });
    assert.equal(sync().action, "ignored", "Unbound MR requires explicit unambiguous ownership");
    const updated = sync({ allowInitialBinding: true });
    assert.equal(updated.ok, true);
    assert.equal(updated.statusUpdated, true);
    let record = readRecords(dataFile)[0];
    assert.equal(record.mrURL, mrURL);
    assert.equal(record.isTested, true);
    const stable = JSON.stringify(readRecords(dataFile));
    assert.equal(sync().action, "unchanged");
    assert.equal(JSON.stringify(readRecords(dataFile)), stable, "Repeat visits must not write timestamps or history");
    assert.equal(sync({ mrURL: "http://example.com/g/p/-/merge_requests/1", allowInitialBinding: true }).action, "ignored");
    assert.equal(sync({ mrState: "closed" }).action, "ignored");
    for (const stage of ["paused", "stopped"]) {
      writeFixture(dataFile, [{ ...record, stage }]);
      assert.equal(sync({ mrState: "merged" }).action, "ignored");
      assert.equal(readRecords(dataFile)[0].stage, stage);
      assert.equal(sendNativeMessage(dataFile, { type: "listAutomaticMRMonitors", payload: {} }).monitors.length, 0);
    }
    writeFixture(dataFile, [{ ...record, mrURL: `${mrURL}1`, mrHistory: [mrURL] }]);
    assert.equal(sync({ mrState: "merged" }).action, "ignored", "Historic MR cannot advance current work");
    writeFixture(dataFile, [record, { ...record, id: "00000000-0000-4000-8000-000000000002", jiraKey: "ZSTAC-23457" }]);
    assert.equal(sync({ mrState: "merged" }).action, "ignored", "Ambiguous saved bindings must not write");
    writeFixture(dataFile, [record]);
    assert.equal(sendNativeMessage(dataFile, { type: "listAutomaticMRMonitors", payload: {} }).monitors.length, 1);
    assert.equal(sync({ mrState: "merged" }).statusUpdated, true);
    record = readRecords(dataFile)[0];
    assert.equal(record.isMerged, true);
    assert.equal(record.statusHistory.at(-1).status, "merged");
    assert.equal(sync().action, "ignored", "Open MR must not downgrade merged status");
    assert.equal(sendNativeMessage(dataFile, { type: "listAutomaticMRMonitors", payload: {} }).monitors.length, 0);
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
}

function testManualActionsAndBatchInspection() {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "requirement-status-actions-"));
  const dataFile = path.join(directory, "requirements.json");
  const issueKey = "ZSTAC-101";
  const send = (type, payload) => sendNativeMessage(dataFile, { type, payload });
  const change = (targetStatus, expectedStatus, reason = "") => send("updateRequirementStatus", {
    issueKey, targetStatus, expectedStatus, reason
  });
  try {
    assert.equal(send("upsertJiraRequirement", { issueKey, targetStatus: "active" }).ok, true);
    let before = JSON.stringify(readRecords(dataFile));
    const batch = send("inspectRequirements", { issueKeys: [issueKey, "ZSTAC-102", issueKey.toLowerCase()] });
    assert.equal(batch.ok, true);
    assert.equal(batch.requirements.length, 2);
    assert.equal(batch.requirements[0].status, "active");
    assert.equal(batch.requirements[1].exists, false);
    assert.equal(JSON.stringify(readRecords(dataFile)), before, "List inspection must not change records");
    assert.equal(change("paused", "active", "  ").ok, false);
    assert.equal(JSON.stringify(readRecords(dataFile)), before);
    assert.equal(change("paused", "active", "  等待接口  ").ok, true);
    let record = readRecords(dataFile)[0];
    assert.equal(record.stage, "paused");
    assert.equal(record.pauseReason, "等待接口");
    const count = record.statusHistory.length;
    assert.equal(change("paused", "paused", "等待字段确认").ok, false);
    assert.equal(readRecords(dataFile)[0].statusHistory.length, count, "Repeated status must not duplicate history");
    before = JSON.stringify(readRecords(dataFile));
    assert.equal(change("stopped", "active", "过期窗口").ok, false);
    assert.equal(JSON.stringify(readRecords(dataFile)), before, "Stale actions must not overwrite newer status");
    assert.equal(change("stopped", "paused", "需求取消").ok, true);
    assert.equal(change("merged", "stopped", "完成").ok, true);
    assert.equal(send("upsertJiraRequirement", { issueKey, targetStatus: "active", reopen: true }).ok, true);
    assert.equal(change("merged", "active").ok, false);
    assert.equal(change("merged", "active", "无需代码修改，配置已完成").ok, true);
    record = readRecords(dataFile)[0];
    assert.equal(record.isMerged, true);
    assert.equal(record.isDone, true);
    assert.equal(record.isTested, true);
    assert.equal(record.pauseReason, "");
    assert.equal(record.note, "无需代码修改，配置已完成");
    assert.equal(record.statusHistory.at(-1).status, "merged");
    assert.ok(!record.statusHistory.some((event) => ["done", "tested"].includes(event.status)),
      "Direct completion must not invent intermediate operations");
    assert.equal(change("paused", "merged", "需要补充验收").ok, true);
    assert.equal(readRecords(dataFile)[0].note, record.note);

    send("upsertJiraRequirement", { issueKey, targetStatus: "active", reopen: true });
    send("attachMergeRequest", { issueKey, mrURL: "http://gitlab.zstack.io/g/p/-/merge_requests/101" });
    assert.equal(change("merged", "active").ok, false, "All manual completion needs an explanation");
    assert.equal(change("merged", "active", "验收完成").ok, true);
    record = readRecords(dataFile)[0];

    // 人工校正覆盖所有来源状态；关联 MR 与历史不能随着状态回退丢失。
    for (const source of ["pending", "active", "done", "tested", "paused", "stopped", "merged"]) {
      for (const target of ["paused", "stopped", "merged"]) {
        const fixture = { ...record, stage: ["done", "tested", "merged"].includes(source) ? "completed" : source,
          isDone: ["done", "tested", "merged"].includes(source), isTested: ["tested", "merged"].includes(source),
          isMerged: source === "merged", pauseReason: "旧原因",
          statusHistory: [{ id: "00000000-0000-4000-8000-000000000003", status: source, date: record.updatedAt }] };
        writeFixture(dataFile, [fixture]);
        const result = change(target, source, "人工确认调整");
        assert.equal(result.ok, source !== target, `${source} -> ${target}`);
        const updated = readRecords(dataFile)[0];
        assert.equal(updated.mrURL, fixture.mrURL);
        assert.equal(updated.statusHistory[0].status, source);
        assert.equal(updated.statusHistory.length, source === target ? 1 : 2);
        assert.equal(send("inspectRequirement", { issueKey }).status, source === target ? source : target);
        if (source !== target && target !== "merged") assert.equal(updated.isMerged, false);
      }
    }
    writeFixture(dataFile, [record, { ...record, id: "00000000-0000-4000-8000-000000000002" }]);
    assert.equal(send("inspectRequirements", { issueKeys: [issueKey] }).requirements[0].ambiguous, true);
    assert.equal(change("paused", "merged", "重复记录").ok, false);
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
}

try {
  run();
  testAutomaticStatusPersistence();
  testManualActionsAndBatchInspection();
  console.log("native-host.behavior.test.js passed");
} catch (error) {
  console.error(error);
  process.exitCode = 1;
}

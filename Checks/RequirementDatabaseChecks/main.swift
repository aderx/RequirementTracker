import Foundation
import RequirementCore

func expect(_ condition: Bool, _ message: String) {
    guard condition else { fatalError(message) }
}
func expectFailure(_ message: String, _ body: () throws -> Void) {
    do { try body(); fatalError(message) } catch { }
}
let folder = FileManager.default.temporaryDirectory.appendingPathComponent("requirement-db-checks-\(UUID())")
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: folder) }
let json = folder.appendingPathComponent("requirements.json")
let url = folder.appendingPathComponent("requirements.sqlite")
let time = Date(timeIntervalSince1970: 1_700_000_000)
let first = Requirement(jiraKey: "TEST-1", jiraURL: "https://example.test/TEST-1", title: "数据库迁移", createdAt: time, updatedAt: time)
let second = Requirement(jiraKey: "TEST-2", jiraURL: "https://example.test/TEST-2", title: "MCP", createdAt: time, updatedAt: time)
var original = try [first, second].map(RequirementDatabase.record)
original[0]["futureMetadata"] = ["preserve": true]
original[0].removeValue(forKey: "statusHistory")
let bytes = try JSONSerialization.data(withJSONObject: original)
try bytes.write(to: json)
let db = try RequirementDatabase(url: url)
expect(try db.load().count == 2, "migration count")
expect(try Data(contentsOf: json) == bytes, "legacy JSON remains untouched")
expect(try FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("Backups").path).count == 1, "migration backup")
expect(try db.load() == db.load(), "legacy derived status event IDs must be stable")
let reopened = try RequirementDatabase(url: url)
expect(try reopened.load().count == 2, "idempotent migration")
let before = try db.load()
var remote = before
remote[1].title = "浏览器更新"
_ = try reopened.applyChanges(before: before, after: remote)
var local = before
local[0].note = "App 更新"
let merged = try db.applyChanges(before: before, after: local)
expect(merged[1].title == "浏览器更新" && merged[0].note == "App 更新", "unrelated concurrent edits survive")
expect(try db.loadRecords()[0]["futureMetadata"] != nil, "unknown metadata survives App edits")
expectFailure("same-record stale changes must fail") { _ = try db.applyChanges(before: before, after: remote) }
expect(try db.load() == merged, "conflict leaves database intact")
expectFailure("transaction must roll back") {
    try db.transaction {
        try db.replaceRecords([])
        throw RequirementDatabaseError.failure("rollback")
    }
}
expect(try db.load().count == 2, "transaction rollback restored rows")
expectFailure("duplicate IDs must fail") { try db.replaceRecords([original[0], original[0]]) }
expect(try db.load().count == 2, "duplicate failure is atomic")
let reader = try RequirementDatabase(url: url, readOnly: true)
expectFailure("readonly must reject writes") { try reader.replaceRecords([]) }
expect(try reader.list(query: "数据库").count == 1, "Chinese search")
expect(try reader.list(query: "' OR 1=1 --").isEmpty, "bound SQL parameters")
expect(try reader.detail(identifier: "test-1") != nil, "case insensitive key lookup")
expect(try reader.statistics()["pending"] == 2, "status stats")
let missing = folder.appendingPathComponent("absent.sqlite")
expectFailure("readonly must not create a database") { _ = try RequirementDatabase(url: missing, readOnly: true) }
expect(!FileManager.default.fileExists(atPath: missing.path), "no readonly creation")
let badJSON = folder.appendingPathComponent("corrupt.json")
let badDB = folder.appendingPathComponent("corrupt.sqlite")
try Data("{broken".utf8).write(to: badJSON)
expectFailure("corrupt legacy JSON must stop migration") { _ = try RequirementDatabase(url: badDB) }
try bytes.write(to: badJSON)
expect(try RequirementDatabase(url: badDB).load().count == 2, "failed migration can retry from intact source")
let newJSON = folder.appendingPathComponent("new.json")
try Data("[]".utf8).write(to: newJSON)
expect(try RequirementDatabase(url: folder.appendingPathComponent("new.sqlite")).load().isEmpty, "empty migration")
var deleted = try db.load()
deleted.removeFirst()
_ = try db.applyChanges(before: db.load(), after: deleted)
expect(try db.load().count == 1, "deletion")
print("RequirementDatabaseChecks passed: migration, backup, stable history, conflict, rollback, SQL filters, readonly")

import CSQLite
import CryptoKit
import Foundation

public enum RequirementDatabaseError: LocalizedError {
    case failure(String)
    case sqlite(Int32, String)
    public var errorDescription: String? {
        switch self {
        case .failure(let message), .sqlite(_, let message): return message
        }
    }
}

/// App、浏览器和 MCP 共用的需求存储。每个进程使用自己的连接，写事务由 SQLite 串行化。
public final class RequirementDatabase {
    public let url: URL
    private var connection: OpaquePointer?
    private let readOnly: Bool
    private var inTransaction = false

    public static var defaultURL: URL {
        if let path = ProcessInfo.processInfo.environment["REQUIREMENT_TRACKER_DATABASE_FILE"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RequirementTracker/requirements.sqlite")
    }

    public init(url: URL = RequirementDatabase.defaultURL, readOnly: Bool = false, legacyJSONURL: URL? = nil, createIfMissing: Bool = true) throws {
        self.url = url
        self.readOnly = readOnly
        if !readOnly && createIfMissing {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        let flags = readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | (createIfMissing ? SQLITE_OPEN_CREATE : 0)
        guard sqlite3_open_v2(url.path, &connection, flags | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let message = errorMessage
            sqlite3_close(connection)
            connection = nil
            throw RequirementDatabaseError.failure("无法打开需求数据库：\(message)")
        }
        do {
            sqlite3_busy_timeout(connection, 5000)
            try execute("PRAGMA foreign_keys = ON")
            if readOnly {
                try execute("PRAGMA query_only = ON")
                guard try (1...2).contains(schemaVersion()) else {
                    throw RequirementDatabaseError.failure("数据库尚未迁移或版本不支持，请先启动 2.0 App。")
                }
            } else {
                try enableWAL()
                try execute("PRAGMA synchronous = FULL")
                try migrate(legacyJSONURL: legacyJSONURL ?? url.deletingPathExtension().appendingPathExtension("json"))
            }
        } catch {
            sqlite3_close(connection)
            connection = nil
            throw error
        }
    }

    deinit { sqlite3_close(connection) }

    private func enableWAL() throws {
        // 首次建库可能由多个 Native Host 同时触发；切换日志模式的锁升级不总是调用 busy handler。
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while true {
            do {
                try execute("PRAGMA journal_mode = WAL")
                return
            } catch RequirementDatabaseError.sqlite(let code, _) where
                (code == SQLITE_BUSY || code == SQLITE_LOCKED) && ProcessInfo.processInfo.systemUptime < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
    }

    public func transaction<T>(_ body: () throws -> T) throws -> T {
        if inTransaction { return try body() }
        guard !readOnly else { throw RequirementDatabaseError.failure("只读连接不允许写入。") }
        try execute("BEGIN IMMEDIATE")
        inTransaction = true
        defer { inTransaction = false }
        do {
            let value = try body()
            try execute("COMMIT")
            return value
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func migrate(legacyJSONURL: URL) throws {
        try transaction {
            let version = try schemaVersion()
            guard version <= 2 else { throw RequirementDatabaseError.failure("数据库版本高于当前 App，请升级 App。") }
            if version == 2 { return }
            if version == 1 {
                try createMCPStorage()
                return
            }
            var records: [[String: Any]] = []
            if FileManager.default.fileExists(atPath: legacyJSONURL.path) {
                let data = try Data(contentsOf: legacyJSONURL)
                guard let decoded = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                    throw RequirementDatabaseError.failure("旧数据格式错误，迁移已停止，原文件未修改。")
                }
                _ = try Self.decodeRecords(decoded)
                records = decoded
                let backupFolder = url.deletingLastPathComponent().appendingPathComponent("Backups")
                try FileManager.default.createDirectory(at: backupFolder, withIntermediateDirectories: true)
                let backup = backupFolder.appendingPathComponent("requirements.before-sqlite-\(UUID().uuidString).json")
                try data.write(to: backup, options: [.atomic])
            }
            try execute("CREATE TABLE requirements (id TEXT PRIMARY KEY, jira_key TEXT NOT NULL, title TEXT NOT NULL, status TEXT NOT NULL, updated_at TEXT NOT NULL, target_version TEXT, epic_key TEXT, position INTEGER NOT NULL, payload TEXT NOT NULL)")
            try execute("CREATE INDEX requirements_key ON requirements(jira_key COLLATE NOCASE)")
            try execute("CREATE INDEX requirements_status_updated ON requirements(status, updated_at DESC)")
            try execute("CREATE TABLE requirement_mrs (requirement_id TEXT NOT NULL REFERENCES requirements(id) ON DELETE CASCADE, url TEXT NOT NULL, position INTEGER NOT NULL, PRIMARY KEY(requirement_id, url))")
            try execute("CREATE TABLE requirement_status_events (requirement_id TEXT NOT NULL REFERENCES requirements(id) ON DELETE CASCADE, id TEXT NOT NULL, status TEXT NOT NULL, date TEXT NOT NULL, position INTEGER NOT NULL, PRIMARY KEY(requirement_id, position))")
            try replaceRecords(records)
            try createMCPStorage()
        }
    }

    private func createMCPStorage() throws {
        try execute("CREATE TABLE mcp_settings (id INTEGER PRIMARY KEY CHECK(id = 1), allow_advance INTEGER NOT NULL DEFAULT 0)")
        try execute("INSERT INTO mcp_settings(id, allow_advance) VALUES(1, 0)")
        // 不级联删除：重试凭据和操作记录在需求删除后仍须保留。
        try execute("CREATE TABLE mcp_operations (request_id TEXT PRIMARY KEY, requirement_id TEXT NOT NULL, request_json TEXT NOT NULL, result_json TEXT NOT NULL, created_at TEXT NOT NULL)")
        try execute("CREATE INDEX mcp_operations_requirement ON mcp_operations(requirement_id)")
        try execute("PRAGMA user_version = 2")
    }

    public func mcpAdvancementEnabled() throws -> Bool {
        guard try schemaVersion() >= 2 else { return false }
        return try query("SELECT allow_advance FROM mcp_settings WHERE id = 1").first?["allow_advance"] == "1"
    }

    public func setMCPAdvancementEnabled(_ enabled: Bool) throws {
        try transaction { try execute("UPDATE mcp_settings SET allow_advance = ? WHERE id = 1", [enabled ? "1" : "0"]) }
    }

    public func mcpOperations(requirementID: String? = nil, limit: Int = 20) throws -> [[String: Any]] {
        guard try schemaVersion() >= 2 else { return [] }
        let filter = requirementID == nil ? "" : " WHERE requirement_id = ?"
        let values = (requirementID.map { [$0] } ?? []) + [String(min(max(limit, 1), 100))]
        return try query("SELECT result_json FROM mcp_operations" + filter + " ORDER BY rowid DESC LIMIT ?", values)
            .map { try Self.object(Data($0["result_json"]!.utf8)) }
    }

    /// 内容摘要包括状态历史事件 ID，可检测同秒内的修改；所有写入方均无需维护额外版本号。
    public static func revision(of record: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public func mcpWorkflow(record: [String: Any]) throws -> [String: Any] {
        let model = try Self.decodeRecords([record])[0]
        return ["revision": try Self.revision(of: record),
                "advancementEnabled": try mcpAdvancementEnabled(),
                "nextStatus": model.nextTimelineStatus.map { $0.rawValue as Any } ?? NSNull(),
                "nextStatusTitle": model.nextTimelineStatus.map { $0.title as Any } ?? NSNull(),
                "condition": model.nextStepRequirement]
    }

    public func advanceFromMCP(identifier: String, expectedRevision: String, requestID: String,
                               reason: String, mergedMRURL: String?) throws -> [String: Any] {
        try transaction {
            guard try mcpAdvancementEnabled() else {
                throw RequirementDatabaseError.failure("Agent 状态维护未开启，请在 App 的设置 → MCP 中开启。")
            }
            let request: [String: Any] = ["identifier": identifier.lowercased(), "expectedRevision": expectedRevision,
                                          "reason": reason, "mergedMRURL": mergedMRURL as Any? ?? NSNull()]
            let requestJSON = String(decoding: try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys]), as: UTF8.self)
            if let previous = try query("SELECT request_json, result_json FROM mcp_operations WHERE request_id = ?", [requestID]).first {
                guard previous["request_json"] == requestJSON else {
                    throw RequirementDatabaseError.failure("request_id 已用于另一操作；重试必须保留原始参数。")
                }
                var result = try Self.object(Data(previous["result_json"]!.utf8))
                result["replayed"] = true
                return result
            }
            guard let raw = try detail(identifier: identifier) else {
                throw RequirementDatabaseError.failure("未找到需求：\(identifier)")
            }
            guard try Self.revision(of: raw) == expectedRevision else {
                throw RequirementDatabaseError.failure("需求已变化，本次未推进。请重新读取并核对下一步条件，不要直接重试推进。")
            }
            var model = try Self.decodeRecords([raw])[0]
            let before = model
            let oldStatus = model.currentTimelineStatus
            if model.nextTimelineStatus == .merged {
                guard let mergedMRURL, let currentMR = model.mrURL,
                      RequirementParser.normalizedURL(mergedMRURL) == RequirementParser.normalizedURL(currentMR),
                      let url = URL(string: mergedMRURL), ["http", "https"].contains(url.scheme ?? ""), url.host != nil else {
                    throw RequirementDatabaseError.failure("请先确认当前 MR 已合并，并传入与需求当前 MR 一致的 merged_mr_url。服务不会自行查询 GitLab。")
                }
            } else if mergedMRURL != nil {
                throw RequirementDatabaseError.failure("当前下一步不是合并，请重新读取需求；本次未推进。")
            }
            let now = Date()
            try model.advanceToNextStatus(at: now)
            model.recordStatus(model.currentTimelineStatus, at: now)
            model.updatedAt = now
            _ = try applyChanges(before: [before], after: [model])
            let saved = try detail(identifier: model.id.uuidString)!
            let result: [String: Any] = ["requestID": requestID, "requirementID": model.id.uuidString,
                "jiraKey": model.jiraKey, "source": "mcp", "reason": reason,
                "previousStatus": oldStatus.rawValue, "previousStatusTitle": oldStatus.title,
                "status": model.currentTimelineStatus.rawValue, "statusTitle": model.displayStatus,
                "mergedMRURL": mergedMRURL as Any? ?? NSNull(), "date": Self.dateString(now),
                "workflow": try mcpWorkflow(record: saved), "replayed": false]
            let resultJSON = String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self)
            try execute("INSERT INTO mcp_operations VALUES(?,?,?,?,?)", [requestID, model.id.uuidString, requestJSON, resultJSON, Self.dateString(now)])
            return result
        }
    }

    public func loadRecords() throws -> [[String: Any]] {
        try query("SELECT payload FROM requirements ORDER BY position, id").map { row in
            try Self.object(Data(row["payload"]!.utf8))
        }
    }

    public func load() throws -> [Requirement] { try Self.decodeRecords(loadRecords()) }

    /// 只提交当前界面实际修改的记录，避免旧快照覆盖浏览器刚写入的其他需求。
    /// 同一需求发生并发编辑时拒绝整笔修改，交给界面重载后重试。
    public func applyChanges(before: [Requirement], after: [Requirement]) throws -> [Requirement] {
        try transaction {
            var records = try loadRecords()
            let current = try Self.decodeRecords(records)
            let old = Dictionary(uniqueKeysWithValues: before.map { ($0.id, $0) })
            let desired = Dictionary(uniqueKeysWithValues: after.map { ($0.id, $0) })
            let live = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
            for id in Set(old.keys).union(desired.keys) where old[id] != desired[id] {
                guard live[id] == old[id] else {
                    throw RequirementDatabaseError.failure("需求已被其他进程更新，本次修改未保存，请重试。")
                }
                if let value = desired[id] {
                    let newRecord = try Self.record(value)
                    if let index = records.firstIndex(where: { ($0["id"] as? String)?.lowercased() == id.uuidString.lowercased() }) {
                        // 保留当前版本尚不认识的字段，兼容未来新增的需求元数据。
                        let oldRecord = try Self.record(old[id]!)
                        for key in Set(oldRecord.keys).union(newRecord.keys) { records[index][key] = newRecord[key] }
                    } else {
                        records.append(newRecord)
                    }
                } else {
                    records.removeAll { ($0["id"] as? String)?.lowercased() == id.uuidString.lowercased() }
                }
            }
            try replaceRecords(records)
            return try Self.decodeRecords(records)
        }
    }

    /// Native Host 在包含“读取—业务判断—写入”的同一个事务中调用。
    public func replaceRecords(_ records: [[String: Any]]) throws {
        try transaction {
            let models = try Self.decodeRecords(records)
            guard Set(models.map(\.id)).count == models.count else {
                throw RequirementDatabaseError.failure("存在重复需求 ID，保存已取消。")
            }
            let previous = try loadRecords()
            let retained = Set(models.map { $0.id.uuidString })
            for record in previous {
                if let id = record["id"] as? String, !retained.contains(id.uppercased()) {
                    try execute("DELETE FROM requirements WHERE id = ?", [id.uppercased()])
                }
            }
            for (position, pair) in zip(records, models).enumerated() {
                let (original, model) = pair
                var raw = original
                if (raw["statusHistory"] as? [[String: Any]])?.isEmpty != false {
                    raw["statusHistory"] = try Self.record(model)["statusHistory"]
                }
                let id = model.id.uuidString
                let payload = String(decoding: try JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys]), as: UTF8.self)
                let existing = try query("SELECT payload, position FROM requirements WHERE id = ?", [id]).first
                if existing?["payload"] == payload && existing?["position"] == String(position) { continue }
                try execute("INSERT INTO requirements(id,jira_key,title,status,updated_at,target_version,epic_key,position,payload) VALUES(?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET jira_key=excluded.jira_key,title=excluded.title,status=excluded.status,updated_at=excluded.updated_at,target_version=excluded.target_version,epic_key=excluded.epic_key,position=excluded.position,payload=excluded.payload", [id, model.jiraKey, model.title, model.currentTimelineStatus.rawValue, Self.dateString(model.updatedAt), model.targetVersion, model.epicKey, String(position), payload])
                try execute("DELETE FROM requirement_mrs WHERE requirement_id = ?", [id])
                for (index, mr) in model.allMRURLs.enumerated() {
                    try execute("INSERT INTO requirement_mrs VALUES(?,?,?)", [id, mr, String(index)])
                }
                try execute("DELETE FROM requirement_status_events WHERE requirement_id = ?", [id])
                for (index, event) in model.statusHistory.enumerated() {
                    try execute("INSERT INTO requirement_status_events VALUES(?,?,?,?,?)", [id, event.id.uuidString, event.status.rawValue, Self.dateString(event.date), String(index)])
                }
            }
        }
    }

    public func exportJSON(to destination: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: loadRecords(), options: [.prettyPrinted, .sortedKeys])
        try data.write(to: destination, options: [.atomic])
    }

    public func list(query text: String? = nil, status: String? = nil, version: String? = nil, epic: String? = nil, limit: Int = 50, offset: Int = 0) throws -> [[String: Any]] {
        var filters: [String] = []
        var values: [String?] = []
        if let text, !text.isEmpty {
            filters.append("(instr(lower(jira_key), lower(?)) > 0 OR instr(lower(title), lower(?)) > 0)")
            values += [text, text]
        }
        if let status { filters.append("status = ?"); values.append(status) }
        if let version { filters.append("target_version = ?"); values.append(version) }
        if let epic { filters.append("epic_key = ? COLLATE NOCASE"); values.append(epic) }
        let whereClause = filters.isEmpty ? "" : " WHERE " + filters.joined(separator: " AND ")
        values += [String(min(max(limit, 1), 100)), String(max(offset, 0))]
        return try query("SELECT payload FROM requirements" + whereClause + " ORDER BY updated_at DESC, id LIMIT ? OFFSET ?", values).map { try Self.object(Data($0["payload"]!.utf8)) }
    }

    public func detail(identifier: String) throws -> [String: Any]? {
        let matches = try query("SELECT payload FROM requirements WHERE id = ? COLLATE NOCASE OR jira_key = ? COLLATE NOCASE", [identifier, identifier])
        guard matches.count <= 1 else { throw RequirementDatabaseError.failure("Jira 编号对应多条记录，请使用需求 UUID 查询。") }
        return try matches.first.map { try Self.object(Data($0["payload"]!.utf8)) }
    }

    public func statistics() throws -> [String: Int] {
        var counts: [String: Int] = [:]
        for row in try query("SELECT status, COUNT(*) AS count FROM requirements GROUP BY status") {
            counts[row["status"]!] = Int(row["count"]!)!
        }
        return counts
    }

    public static func record(_ requirement: Requirement) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try object(encoder.encode(requirement))
    }

    public static func decodeRecords(_ records: [[String: Any]]) throws -> [Requirement] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([Requirement].self, from: JSONSerialization.data(withJSONObject: records))
    }

    private static func object(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RequirementDatabaseError.failure("需求记录格式错误。")
        }
        return object
    }

    private static func dateString(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
    private var errorMessage: String { connection.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite connection unavailable" }
    private func schemaVersion() throws -> Int { Int(try query("PRAGMA user_version").first?["user_version"] ?? "0") ?? 0 }
    private func execute(_ sql: String, _ values: [String?] = []) throws { _ = try query(sql, values) }

    private func query(_ sql: String, _ values: [String?] = []) throws -> [[String: String]] {
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(connection, sql, -1, &statement, nil)
        guard prepared == SQLITE_OK else {
            throw RequirementDatabaseError.sqlite(prepared, errorMessage)
        }
        defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() {
            let result: Int32
            if let value {
                result = value.withCString { sqlite3_bind_text(statement, Int32(index + 1), $0, Int32(value.utf8.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            } else {
                result = sqlite3_bind_null(statement, Int32(index + 1))
            }
            guard result == SQLITE_OK else { throw RequirementDatabaseError.sqlite(result, errorMessage) }
        }
        var rows: [[String: String]] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return rows }
            guard result == SQLITE_ROW else { throw RequirementDatabaseError.sqlite(result, errorMessage) }
            var row: [String: String] = [:]
            for column in 0..<sqlite3_column_count(statement) {
                if let value = sqlite3_column_text(statement, column) {
                    let count = Int(sqlite3_column_bytes(statement, column))
                    row[String(cString: sqlite3_column_name(statement, column))] = String(decoding: UnsafeBufferPointer(start: value, count: count), as: UTF8.self)
                }
            }
            rows.append(row)
        }
    }
}

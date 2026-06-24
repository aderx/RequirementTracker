import Foundation
import RequirementCore

private let hostName = RequirementPluginSettings.defaultNativeHostName

do {
    let request = try NativeMessage.read()
    let response = try handle(request: request)
    try NativeMessage.write(response)
} catch {
    let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    try? NativeMessage.write([
        "ok": false,
        "host": hostName,
        "error": message
    ])
}

private func handle(request: [String: Any]) throws -> [String: Any] {
    let writer = RequirementJSONWriter(
        dataFileURL: RequirementJSONWriter.defaultDataFileURL(),
        settingsFileURL: RequirementJSONWriter.defaultSettingsFileURL()
    )

    switch stringValue(request["type"]) {
    case "getPluginSettings":
        return try writer.pluginSettingsResponse()
    case "inspectRequirement":
        return try writer.inspect(payload: requiredPayload(from: request))
    case "inspectByURL":
        return try writer.inspectByURL(payload: requiredPayload(from: request))
    case "upsertRequirement", "upsertJiraRequirement":
        return try writer.upsertJiraRequirement(payload: requiredPayload(from: request))
    case "attachMergeRequest":
        return try writer.attachMergeRequest(payload: requiredPayload(from: request))
    default:
        throw HostError.invalidRequest("不支持的消息类型")
    }
}

private func requiredPayload(from request: [String: Any]) throws -> [String: Any] {
    guard let payload = request["payload"] as? [String: Any] else {
        throw HostError.invalidRequest("缺少 payload")
    }

    return payload
}

private struct RequirementJSONWriter {
    let dataFileURL: URL
    let settingsFileURL: URL

    func pluginSettingsResponse() throws -> [String: Any] {
        let settings = try loadToolConfiguration().pluginSettings.normalized
        return [
            "ok": true,
            "host": hostName,
            "settings": [
                "jiraBaseURL": settings.jiraBaseURL,
                "mrHosts": settings.validMRHosts,
                "chromeExtensionID": settings.chromeExtensionID,
                "nativeHostName": RequirementPluginSettings.defaultNativeHostName
            ],
            "settingsFilePath": settingsFileURL.path
        ]
    }

    func inspect(payload: [String: Any]) throws -> [String: Any] {
        let issueKey = try issueKey(from: payload)
        let records = try loadRecords()
        let record = records.first { matchesIssueKey($0, issueKey: issueKey) }
        let jiraURL = record.flatMap { stringValue($0["jiraURL"]) }
            ?? jiraURL(from: payload, issueKey: issueKey)

        var response: [String: Any] = [
            "ok": true,
            "host": hostName,
            "exists": record != nil,
            "issueKey": issueKey,
            "jiraURL": jiraURL,
            "dataFilePath": dataFileURL.path
        ]

        if let mrURL = record.flatMap({ stringValue($0["mrURL"]) }), !mrURL.isEmpty {
            response["mrURL"] = RequirementParser.normalizedURL(mrURL)
            response["hasMR"] = true
        } else {
            response["hasMR"] = false
        }

        return response
    }

    /// 按页面地址判断是否已记录：Jira 详情页按编号匹配，其它页面按 Jira/MR 地址匹配。
    /// 供浏览器插件给图标标记使用。
    func inspectByURL(payload: [String: Any]) throws -> [String: Any] {
        let rawURL = stringValue(payload["url"])
            ?? stringValue(payload["jiraURL"])
            ?? stringValue(payload["mrURL"])
            ?? ""
        let normalized = RequirementParser.normalizedURL(rawURL)
        let issueKey = RequirementParser.jiraKey(from: rawURL) ?? ""

        let records = try loadRecords()
        let record = records.first { record in
            if !issueKey.isEmpty, matchesIssueKey(record, issueKey: issueKey) {
                return true
            }

            guard !normalized.isEmpty else {
                return false
            }

            let recordJiraURL = RequirementParser.normalizedURL(stringValue(record["jiraURL"]) ?? "")
            let recordMRURL = RequirementParser.normalizedURL(stringValue(record["mrURL"]) ?? "")
            return recordJiraURL == normalized || recordMRURL == normalized
        }

        return [
            "ok": true,
            "host": hostName,
            "exists": record != nil,
            "issueKey": issueKey,
            "dataFilePath": dataFileURL.path
        ]
    }

    func upsertJiraRequirement(payload: [String: Any]) throws -> [String: Any] {
        let issueKey = try issueKey(from: payload)
        let now = ISO8601DateFormatter().string(from: Date())
        let capturedAt = stringValue(payload["capturedAt"]) ?? now
        let normalizedJiraURL = jiraURL(from: payload, issueKey: issueKey)
        let startDevelopment = boolValue(payload["startDevelopment"]) ?? false

        var records = try loadRecords()
        let index = records.firstIndex { matchesIssueKey($0, issueKey: issueKey) }

        let action: String
        var didStart = false
        if let index {
            records[index]["jiraKey"] = issueKey
            records[index]["jiraURL"] = normalizedJiraURL
            records[index]["updatedAt"] = now
            applyJiraFields(from: payload, to: &records[index], capturedAt: capturedAt)
            if startDevelopment {
                didStart = beginDevelopmentIfNeeded(&records[index], now: now)
            }
            action = "updated"
        } else {
            var record = baseRecord(issueKey: issueKey, jiraURL: normalizedJiraURL, now: now)
            applyJiraFields(from: payload, to: &record, capturedAt: capturedAt)
            if startDevelopment {
                record["stage"] = "active"
                didStart = true
            }
            records.append(record)
            action = "created"
        }

        return try persist(records: records, action: action, issueKey: issueKey, started: didStart)
    }

    /// 仅当需求处于「未开始（待开发）」时转为开发中并补记一条状态事件；
    /// 已开始/已完成/已暂停/已停止等保持不变。返回是否真正发生了转换。
    private func beginDevelopmentIfNeeded(_ record: inout [String: Any], now: String) -> Bool {
        let stage = stringValue(record["stage"]) ?? "pending"
        let isDone = boolValue(record["isDone"]) ?? false
        let isTested = boolValue(record["isTested"]) ?? false
        let isMerged = boolValue(record["isMerged"]) ?? false

        guard stage == "pending", !isDone, !isTested, !isMerged else {
            return false
        }

        record["stage"] = "active"
        appendStatusEvent(to: &record, status: "active", date: now)
        return true
    }

    /// 向记录的状态历史追加一条事件，保持与 App 端 recordStatus 一致的去重与首条补齐逻辑。
    private func appendStatusEvent(to record: inout [String: Any], status: String, date: String) {
        var history = (record["statusHistory"] as? [[String: Any]]) ?? []

        if let last = history.last, stringValue(last["status"]) == status {
            return
        }

        if history.isEmpty {
            let createdAt = stringValue(record["createdAt"]) ?? date
            history.append([
                "id": UUID().uuidString,
                "status": "pending",
                "date": createdAt
            ])
        }

        history.append([
            "id": UUID().uuidString,
            "status": status,
            "date": date
        ])
        record["statusHistory"] = history
    }

    func attachMergeRequest(payload: [String: Any]) throws -> [String: Any] {
        let issueKey = try issueKey(from: payload)
        let normalizedJiraURL = jiraURL(from: payload, issueKey: issueKey)
        let normalizedMRURL = RequirementParser.normalizedURL(try requiredString(payload["mrURL"], field: "mrURL"))
        guard !normalizedMRURL.isEmpty else {
            throw HostError.invalidRequest("缺少 mrURL")
        }

        let replaceExisting = boolValue(payload["replaceExisting"]) ?? false
        let now = ISO8601DateFormatter().string(from: Date())
        var records = try loadRecords()
        let index = records.firstIndex { matchesIssueKey($0, issueKey: issueKey) }

        let action: String
        if let index {
            let existingMRURL = RequirementParser.normalizedURL(stringValue(records[index]["mrURL"]) ?? "")
            if !existingMRURL.isEmpty, existingMRURL != normalizedMRURL, !replaceExisting {
                return [
                    "ok": true,
                    "host": hostName,
                    "action": "needsReplacement",
                    "issueKey": issueKey,
                    "jiraURL": normalizedJiraURL,
                    "mrURL": existingMRURL,
                    "newMRURL": normalizedMRURL,
                    "dataFilePath": dataFileURL.path
                ]
            }

            records[index]["jiraKey"] = issueKey
            records[index]["jiraURL"] = normalizedJiraURL
            records[index]["mrURL"] = normalizedMRURL
            records[index]["updatedAt"] = now
            action = existingMRURL.isEmpty ? "attached" : "replaced"
        } else {
            var record = baseRecord(issueKey: issueKey, jiraURL: normalizedJiraURL, now: now)
            record["mrURL"] = normalizedMRURL
            records.append(record)
            action = "created"
        }

        return try persist(records: records, action: action, issueKey: issueKey, mrURL: normalizedMRURL)
    }

    private func persist(
        records: [[String: Any]],
        action: String,
        issueKey: String,
        mrURL: String? = nil,
        started: Bool = false
    ) throws -> [String: Any] {
        let backupURL = try backupExistingFileIfNeeded(kind: "before-browser-import")
        try write(records: records)
        let snapshotURL = try backupExistingFileIfNeeded(kind: "after-browser-import")
        notifyApp(action: action, issueKey: issueKey)

        var response: [String: Any] = [
            "ok": true,
            "host": hostName,
            "action": action,
            "issueKey": issueKey,
            "started": started,
            "dataFilePath": dataFileURL.path
        ]

        if let mrURL {
            response["mrURL"] = mrURL
        }

        if let backupURL {
            response["backupPath"] = backupURL.path
        }

        if let snapshotURL {
            response["snapshotPath"] = snapshotURL.path
        }

        return response
    }

    private func notifyApp(action: String, issueKey: String) {
        DistributedNotificationCenter.default().postNotificationName(
            RequirementExternalUpdateNotification.name,
            object: hostName,
            userInfo: [
                "action": action,
                "issueKey": issueKey
            ],
            deliverImmediately: true
        )
    }

    private func baseRecord(issueKey: String, jiraURL: String, now: String) -> [String: Any] {
        [
            "id": UUID().uuidString,
            "jiraKey": issueKey,
            "jiraURL": jiraURL,
            "note": "",
            "pauseReason": "",
            "stage": "pending",
            "isDone": false,
            "isTested": false,
            "isMerged": false,
            "createdAt": now,
            "updatedAt": now
        ]
    }

    private func issueKey(from payload: [String: Any]) throws -> String {
        let candidates = [
            stringValue(payload["issueKey"]),
            stringValue(payload["jiraKey"]),
            stringValue(payload["jiraURL"]),
            stringValue(payload["url"])
        ].compactMap { $0 }

        for candidate in candidates {
            if let key = RequirementParser.jiraKey(from: candidate) {
                return key
            }
        }

        throw HostError.invalidRequest("缺少 Jira 编号")
    }

    private func jiraURL(from payload: [String: Any], issueKey: String) -> String {
        let source = stringValue(payload["jiraURL"]) ?? stringValue(payload["url"]) ?? ""
        if !source.isEmpty, source.lowercased().hasPrefix("http") {
            return RequirementParser.jiraURL(from: source, jiraKey: issueKey)
        }

        let baseURL = (try? loadToolConfiguration().pluginSettings.normalized.jiraBaseURL)
            ?? RequirementParser.defaultJiraBaseURL
        return baseURL + issueKey
    }

    private func matchesIssueKey(_ record: [String: Any], issueKey: String) -> Bool {
        stringValue(record["jiraKey"])?.uppercased() == issueKey
            || stringValue(record["issueKey"])?.uppercased() == issueKey
    }

    private func applyJiraFields(from payload: [String: Any], to record: inout [String: Any], capturedAt: String) {
        setIfPresent("title", from: payload, to: &record, as: "title")
        setIfPresent("type", from: payload, to: &record, as: "issueType")
        setIfPresent("priority", from: payload, to: &record, as: "priority")
        setIfPresent("targetVersion", from: payload, to: &record, as: "targetVersion")
        record["jiraCapturedAt"] = capturedAt
    }

    private func setIfPresent(
        _ sourceKey: String,
        from payload: [String: Any],
        to record: inout [String: Any],
        as targetKey: String
    ) {
        guard let value = stringValue(payload[sourceKey]), !value.isEmpty else {
            return
        }

        record[targetKey] = value
    }

    private func loadToolConfiguration() throws -> RequirementToolConfiguration {
        guard FileManager.default.fileExists(atPath: settingsFileURL.path) else {
            return RequirementToolConfiguration()
        }

        let data = try Data(contentsOf: settingsFileURL)
        guard !data.isEmpty else {
            return RequirementToolConfiguration()
        }

        return try JSONDecoder().decode(RequirementToolConfiguration.self, from: data).normalized
    }

    private func loadRecords() throws -> [[String: Any]] {
        guard FileManager.default.fileExists(atPath: dataFileURL.path) else {
            return []
        }

        do {
            let data = try Data(contentsOf: dataFileURL)
            guard !data.isEmpty else {
                return []
            }

            guard
                let records = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
            else {
                throw HostError.invalidDataFile("requirements.json 顶层不是数组")
            }

            return records
        } catch {
            _ = try? backupExistingFileIfNeeded(kind: "corrupt")
            throw HostError.invalidDataFile("读取 requirements.json 失败：\(error.localizedDescription)")
        }
    }

    private func write(records: [[String: Any]]) throws {
        try FileManager.default.createDirectory(
            at: dataFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let data = try JSONSerialization.data(
            withJSONObject: records,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: dataFileURL, options: [.atomic])
    }

    private func backupExistingFileIfNeeded(kind: String) throws -> URL? {
        guard FileManager.default.fileExists(atPath: dataFileURL.path) else {
            return nil
        }

        let backupDirectory = dataFileURL
            .deletingLastPathComponent()
            .appendingPathComponent("Backups", isDirectory: true)
        try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true)

        let timestamp = Self.backupTimestamp()
        let backupURL = backupDirectory
            .appendingPathComponent("requirements.\(kind).\(timestamp).json")

        try FileManager.default.copyItem(at: dataFileURL, to: backupURL)
        return backupURL
    }

    static func defaultDataFileURL() -> URL {
        if let overridePath = ProcessInfo.processInfo.environment["REQUIREMENT_TRACKER_DATA_FILE"],
           !overridePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: overridePath)
        }

        let applicationSupport = applicationSupportDirectory()
        return applicationSupport
            .appendingPathComponent("RequirementTracker", isDirectory: true)
            .appendingPathComponent("requirements.json")
    }

    static func defaultSettingsFileURL() -> URL {
        let applicationSupport = applicationSupportDirectory()
        return applicationSupport
            .appendingPathComponent("RequirementTracker", isDirectory: true)
            .appendingPathComponent("settings.json")
    }

    private static func applicationSupportDirectory() -> URL {
        FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
    }

    private static func backupTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter.string(from: Date())
    }
}

private enum NativeMessage {
    static func read() throws -> [String: Any] {
        let lengthData = try readExactly(byteCount: 4)
        let bytes = [UInt8](lengthData)
        let length = Int(
            UInt32(bytes[0])
                | UInt32(bytes[1]) << 8
                | UInt32(bytes[2]) << 16
                | UInt32(bytes[3]) << 24
        )

        guard length > 0, length <= 1_048_576 else {
            throw HostError.invalidRequest("Native message 长度无效")
        }

        let messageData = try readExactly(byteCount: length)
        guard
            let object = try JSONSerialization.jsonObject(with: messageData) as? [String: Any]
        else {
            throw HostError.invalidRequest("Native message 不是 JSON 对象")
        }

        return object
    }

    static func write(_ object: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        guard data.count <= Int(UInt32.max) else {
            throw HostError.invalidRequest("Native response 过大")
        }

        var length = UInt32(data.count).littleEndian
        let lengthData = Data(bytes: &length, count: 4)
        FileHandle.standardOutput.write(lengthData)
        FileHandle.standardOutput.write(data)
    }

    private static func readExactly(byteCount: Int) throws -> Data {
        var data = Data()

        while data.count < byteCount {
            let chunk = FileHandle.standardInput.readData(ofLength: byteCount - data.count)
            guard !chunk.isEmpty else {
                throw HostError.invalidRequest("Native message 不完整")
            }
            data.append(chunk)
        }

        return data
    }
}

private enum HostError: LocalizedError {
    case invalidRequest(String)
    case invalidDataFile(String)

    var errorDescription: String? {
        switch self {
        case .invalidRequest(let message), .invalidDataFile(let message):
            message
        }
    }
}

private func requiredString(_ value: Any?, field: String) throws -> String {
    guard let value = stringValue(value), !value.isEmpty else {
        throw HostError.invalidRequest("缺少 \(field)")
    }

    return value
}

private func stringValue(_ value: Any?) -> String? {
    guard let value else {
        return nil
    }

    return String(describing: value)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

private func boolValue(_ value: Any?) -> Bool? {
    if let value = value as? Bool {
        return value
    }

    if let value = stringValue(value)?.lowercased() {
        switch value {
        case "true", "1", "yes":
            return true
        case "false", "0", "no":
            return false
        default:
            return nil
        }
    }

    return nil
}

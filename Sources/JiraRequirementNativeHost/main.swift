import Foundation

private let hostName = "com.aderx.requirementtracker.jira_capture"
private let defaultJiraBaseURL = "http://jira.zstack.io/browse/"

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
    guard stringValue(request["type"]) == "upsertRequirement" else {
        throw HostError.invalidRequest("不支持的消息类型")
    }

    guard let payload = request["payload"] as? [String: Any] else {
        throw HostError.invalidRequest("缺少 payload")
    }

    let writer = RequirementJSONWriter(dataFileURL: RequirementJSONWriter.defaultDataFileURL())
    return try writer.upsert(payload: payload)
}

private struct RequirementJSONWriter {
    let dataFileURL: URL

    func upsert(payload: [String: Any]) throws -> [String: Any] {
        let issueKey = try requiredString(payload["issueKey"], field: "issueKey").uppercased()
        let now = ISO8601DateFormatter().string(from: Date())
        let capturedAt = stringValue(payload["capturedAt"]) ?? now
        let jiraURL = stringValue(payload["url"]) ?? "\(defaultJiraBaseURL)\(issueKey)"

        var records = try loadRecords()
        let index = records.firstIndex { record in
            stringValue(record["jiraKey"])?.uppercased() == issueKey
                || stringValue(record["issueKey"])?.uppercased() == issueKey
        }

        let action: String
        if let index {
            records[index]["jiraKey"] = issueKey
            records[index]["jiraURL"] = jiraURL
            applyJiraFields(from: payload, to: &records[index], capturedAt: capturedAt)
            action = "updated"
        } else {
            var record: [String: Any] = [
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
            applyJiraFields(from: payload, to: &record, capturedAt: capturedAt)
            records.append(record)
            action = "created"
        }

        let backupURL = try backupExistingFileIfNeeded(kind: "before-jira-import")
        try write(records: records)
        let snapshotURL = try backupExistingFileIfNeeded(kind: "after-jira-import")

        var response: [String: Any] = [
            "ok": true,
            "host": hostName,
            "action": action,
            "issueKey": issueKey,
            "dataFilePath": dataFileURL.path
        ]

        if let backupURL {
            response["backupPath"] = backupURL.path
        }

        if let snapshotURL {
            response["snapshotPath"] = snapshotURL.path
        }

        return response
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

        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory

        return applicationSupport
            .appendingPathComponent("RequirementTracker", isDirectory: true)
            .appendingPathComponent("requirements.json")
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

import Foundation

public enum RequirementStage: String, CaseIterable, Codable, Identifiable, Sendable {
    case active
    case pending
    case paused
    case stopped
    case completed

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .active:
            "开发中"
        case .pending:
            "待开发"
        case .paused:
            "已暂停"
        case .stopped:
            "已停止"
        case .completed:
            "开发完成"
        }
    }

    public var shortTitle: String {
        switch self {
        case .active:
            "开发中"
        case .pending:
            "待开发"
        case .paused:
            "已暂停"
        case .stopped:
            "已停止"
        case .completed:
            "开发完成"
        }
    }

    public var sortRank: Int {
        switch self {
        case .active:
            0
        case .pending:
            1
        case .paused:
            2
        case .stopped:
            2
        case .completed:
            3
        }
    }
}

public enum RequirementTimelineStatus: String, Codable, Sendable {
    case pending
    case active
    case done
    case tested
    case merged
    case paused
    case stopped
}

public struct RequirementStatusEvent: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var status: RequirementTimelineStatus
    public var date: Date

    public init(
        id: UUID = UUID(),
        status: RequirementTimelineStatus,
        date: Date
    ) {
        self.id = id
        self.status = status
        self.date = date
    }
}

public struct Requirement: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var jiraKey: String
    public var jiraURL: String
    public var mrURL: String?
    public var note: String
    public var pauseReason: String
    public var stage: RequirementStage
    public var isDone: Bool
    public var isTested: Bool
    public var isMerged: Bool
    public var createdAt: Date
    public var updatedAt: Date
    public var completedAt: Date?
    public var statusHistory: [RequirementStatusEvent]

    public init(
        id: UUID = UUID(),
        jiraKey: String,
        jiraURL: String,
        mrURL: String? = nil,
        note: String = "",
        pauseReason: String = "",
        stage: RequirementStage = .pending,
        isDone: Bool = false,
        isTested: Bool = false,
        isMerged: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        completedAt: Date? = nil,
        statusHistory: [RequirementStatusEvent]? = nil
    ) {
        self.id = id
        self.jiraKey = jiraKey
        self.jiraURL = jiraURL
        self.mrURL = mrURL
        self.note = note
        self.pauseReason = pauseReason
        self.stage = stage
        self.isDone = isDone
        self.isTested = isTested
        self.isMerged = isMerged
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.completedAt = completedAt
        self.statusHistory = statusHistory ?? Self.legacyStatusHistory(
            stage: stage,
            isDone: isDone,
            isTested: isTested,
            isMerged: isMerged,
            createdAt: createdAt,
            updatedAt: updatedAt,
            completedAt: completedAt
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case jiraKey
        case jiraURL
        case mrURL
        case note
        case pauseReason
        case stage
        case isDone
        case isTested
        case isMerged
        case createdAt
        case updatedAt
        case completedAt
        case statusHistory
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        jiraKey = try container.decode(String.self, forKey: .jiraKey)
        jiraURL = try container.decode(String.self, forKey: .jiraURL)
        mrURL = try container.decodeIfPresent(String.self, forKey: .mrURL)
        note = try container.decode(String.self, forKey: .note)
        pauseReason = try container.decode(String.self, forKey: .pauseReason)
        stage = try container.decode(RequirementStage.self, forKey: .stage)
        isDone = try container.decode(Bool.self, forKey: .isDone)
        isTested = try container.decode(Bool.self, forKey: .isTested)
        isMerged = try container.decode(Bool.self, forKey: .isMerged)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)

        let decodedHistory = try container.decodeIfPresent([RequirementStatusEvent].self, forKey: .statusHistory) ?? []
        statusHistory = decodedHistory.isEmpty
            ? Self.legacyStatusHistory(
                stage: stage,
                isDone: isDone,
                isTested: isTested,
                isMerged: isMerged,
                createdAt: createdAt,
                updatedAt: updatedAt,
                completedAt: completedAt
            )
            : decodedHistory
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(jiraKey, forKey: .jiraKey)
        try container.encode(jiraURL, forKey: .jiraURL)
        try container.encodeIfPresent(mrURL, forKey: .mrURL)
        try container.encode(note, forKey: .note)
        try container.encode(pauseReason, forKey: .pauseReason)
        try container.encode(stage, forKey: .stage)
        try container.encode(isDone, forKey: .isDone)
        try container.encode(isTested, forKey: .isTested)
        try container.encode(isMerged, forKey: .isMerged)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(completedAt, forKey: .completedAt)
        try container.encode(statusHistory, forKey: .statusHistory)
    }

    public var effectiveStage: RequirementStage {
        if stage == .paused || stage == .stopped {
            return stage
        }

        if stage == .completed || isDone || isMerged {
            return .completed
        }

        return stage
    }

    public var displayStatus: String {
        if stage == .paused {
            return "已暂停"
        }

        if stage == .stopped {
            return "已停止"
        }

        if isMerged {
            return "已合并"
        }

        if isTested {
            return "已测试"
        }

        if isDone {
            return "开发完成"
        }

        return stage.shortTitle
    }

    public var activityDate: Date {
        completedAt ?? updatedAt
    }

    public var hasMergeRequestURL: Bool {
        !(mrURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var combinedCopyText: String {
        let jira = jiraURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let mr = mrURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard !mr.isEmpty else {
            return jira
        }

        return """
        Jira: \(jira)
        MR: \(mr)
        """
    }

    public mutating func recordStatus(_ status: RequirementTimelineStatus, at date: Date) {
        if statusHistory.isEmpty {
            statusHistory = [RequirementStatusEvent(status: .pending, date: createdAt)]
        }

        guard statusHistory.last?.status != status else {
            return
        }

        statusHistory.append(RequirementStatusEvent(status: status, date: date))
    }

    public var currentTimelineStatus: RequirementTimelineStatus {
        if stage == .stopped {
            return .stopped
        }

        if stage == .paused {
            return .paused
        }

        if isMerged {
            return .merged
        }

        if isTested {
            return .tested
        }

        if isDone || stage == .completed {
            return .done
        }

        if stage == .active {
            return .active
        }

        return .pending
    }

    private static func legacyStatusHistory(
        stage: RequirementStage,
        isDone: Bool,
        isTested: Bool,
        isMerged: Bool,
        createdAt: Date,
        updatedAt: Date,
        completedAt: Date?
    ) -> [RequirementStatusEvent] {
        var events = [RequirementStatusEvent(status: .pending, date: createdAt)]
        let completionDate = completedAt ?? updatedAt

        if stage == .active || stage == .completed || isDone || isTested || isMerged {
            events.append(RequirementStatusEvent(status: .active, date: createdAt))
        }

        if stage == .completed || isDone || isTested || isMerged {
            events.append(RequirementStatusEvent(status: .done, date: completionDate))
        }

        if isTested || isMerged {
            events.append(RequirementStatusEvent(status: .tested, date: updatedAt))
        }

        if isMerged {
            events.append(RequirementStatusEvent(status: .merged, date: completionDate))
        }

        if stage == .paused {
            events.append(RequirementStatusEvent(status: .paused, date: updatedAt))
        }

        if stage == .stopped {
            events.append(RequirementStatusEvent(status: .stopped, date: updatedAt))
        }

        return events
    }
}

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
        completedAt: Date? = nil
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
}

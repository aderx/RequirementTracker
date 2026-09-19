import Foundation

/// App 与 Agent 共用线性推进顺序；暂停恢复仍由 App 的显式操作决定。
public extension Requirement {
    var nextTimelineStatus: RequirementTimelineStatus? {
        switch currentTimelineStatus {
        case .pending: .active
        case .active: .done
        case .done: .tested
        case .tested: .merged
        case .merged, .paused, .stopped: nil
        }
    }

    var nextStepRequirement: String {
        switch currentTimelineStatus {
        case .pending: "已经开始实际开发此需求。"
        case .active: "本阶段实现完成，并已执行必要的代码检查。"
        case .done: "已完成自测，需说明实际执行的测试和结果。"
        case .tested: "已向 GitLab 确认当前关联 MR 合并成功，需提供该 MR 地址；提交或打开 MR 不算合并。"
        case .paused: "需求已暂停，请先由用户在 App 中恢复。"
        case .stopped: "需求已停止，不允许自动推进。"
        case .merged: "需求已合并，没有下一状态。"
        }
    }

    mutating func advanceToNextStatus(at now: Date) throws {
        guard let next = nextTimelineStatus else {
            throw RequirementDatabaseError.failure(nextStepRequirement)
        }
        if next == .merged && !hasMergeRequestURL {
            throw RequirementDatabaseError.failure("请先填写 MR 地址")
        }
        switch next {
        case .active: stage = .active
        case .done:
            stage = .completed
            isDone = true
            completedAt = now
        case .tested:
            stage = .completed
            isDone = true
            isTested = true
            completedAt = completedAt ?? now
        case .merged:
            stage = .completed
            isDone = true
            isTested = true
            isMerged = true
            completedAt = now
        default: break
        }
    }
}

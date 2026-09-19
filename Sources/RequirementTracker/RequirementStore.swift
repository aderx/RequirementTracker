import AppKit
import Foundation
import RequirementCore

@MainActor
final class RequirementStore: ObservableObject {
    @Published var requirements: [Requirement] = [] {
        didSet {
            guard !isBootstrapping, !isLoadingFromDisk else {
                return
            }
            save()
        }
    }

    let dataFileURL: URL
    @Published var lastNotice: String?

    private var database: RequirementDatabase?
    private var savedSnapshot: [Requirement] = []
    private var lastSaveSucceeded = true
    private var isBootstrapping = true
    private var isLoadingFromDisk = false

    init(dataFileURL: URL? = nil) {
        self.dataFileURL = dataFileURL ?? RequirementDatabase.defaultURL
        _ = loadFromDisk()
        isBootstrapping = false
    }

    func requirement(id: Requirement.ID) -> Requirement? {
        requirements.first { $0.id == id }
    }

    @discardableResult
    func addFromBulkInput(_ input: String) -> Int {
        let existingKeys = Set(requirements.map(\.jiraKey))
        let parsed = RequirementParser.requirements(fromBulkInput: input)
            .filter { !existingKeys.contains($0.jiraKey) }

        guard !parsed.isEmpty else {
            lastNotice = "没有新增需求"
            return 0
        }

        requirements.append(contentsOf: parsed)
        guard lastSaveSucceeded else { return 0 }
        lastNotice = "已添加 \(parsed.count) 个需求"
        return parsed.count
    }

    func update(
        id: Requirement.ID,
        allowsMergedWithoutMR: Bool = false,
        updatesTimestamp: Bool = true,
        resetsMRTrackingWhenURLChanges: Bool = true,
        _ transform: (inout Requirement) -> Void
    ) {
        guard let index = requirements.firstIndex(where: { $0.id == id }) else {
            return
        }

        var edited = requirements[index]
        let now = Date()
        let previousStatus = edited.currentTimelineStatus
        let previousMRURL = RequirementParser.normalizedURL(edited.mrURL ?? "")
        transform(&edited)
        let nextMRURL = RequirementParser.normalizedURL(edited.mrURL ?? "")
        if resetsMRTrackingWhenURLChanges && nextMRURL != previousMRURL {
            edited.clearMRTracking()
        }
        normalizeRequirement(&edited, now: now, allowsMergedWithoutMR: allowsMergedWithoutMR)
        let nextStatus = edited.currentTimelineStatus
        if nextStatus != previousStatus {
            edited.recordStatus(nextStatus, at: now)
        }
        if updatesTimestamp {
            edited.updatedAt = now
        }
        requirements[index] = edited
    }

    func setStage(id: Requirement.ID, stage: RequirementStage) {
        update(id: id) { requirement in
            requirement.stage = stage

            if stage == .completed {
                requirement.isDone = true
                requirement.completedAt = requirement.completedAt ?? Date()
            }

            if stage == .active || stage == .pending {
                requirement.pauseReason = ""
                requirement.isDone = false
                requirement.isTested = false
                requirement.isMerged = false
                requirement.completedAt = nil
            }

            if stage == .stopped {
                requirement.isMerged = false
            }
        }
    }

    func advance(id: Requirement.ID) {
        update(id: id) { requirement in
            if requirement.isMerged || requirement.stage == .stopped {
                return
            }

            if requirement.stage == .paused {
                requirement.stage = .active
                requirement.isDone = false
                requirement.isTested = false
                requirement.isMerged = false
                requirement.completedAt = nil
                requirement.pauseReason = ""
                return
            }

            do {
                try requirement.advanceToNextStatus(at: Date())
            } catch {
                lastNotice = error.localizedDescription
            }
        }
    }

    /// 已存在 MR 时一键完成：无需补充完成备注，直接转为已完成。
    func markCompleted(id: Requirement.ID) {
        guard
            let requirement = requirement(id: id),
            requirement.canMarkMergedDirectly,
            requirement.hasMergeRequestURL
        else {
            return
        }

        update(id: id) { requirement in
            requirement.pauseReason = ""
            requirement.isMerged = true
        }
        guard lastSaveSucceeded else { return }
        lastNotice = "已标为已完成"
    }

    func markMerged(id: Requirement.ID, note: String) {
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !trimmedNote.isEmpty,
            requirement(id: id)?.canMarkMergedDirectly == true
        else {
            return
        }

        update(id: id, allowsMergedWithoutMR: true) { requirement in
            requirement.note = trimmedNote
            requirement.pauseReason = ""
            requirement.isMerged = true
        }
        guard lastSaveSucceeded else { return }
        lastNotice = "已标为已完成"
    }

    func recordMergeRequestURL(id: Requirement.ID, url: String) {
        update(id: id) { requirement in
            requirement.recordMergeRequestURL(url)
        }
    }

    func markMRMergeRequested(id: Requirement.ID) {
        guard
            let requirement = requirement(id: id),
            !requirement.isMerged,
            requirement.hasMergeRequestURL,
            requirement.mrTrackingStatus == .created
        else {
            return
        }

        setMRTrackingStatus(id: id, status: .mergeRequested)
    }

    func setMRTrackingStatus(id: Requirement.ID, status: RequirementMRTrackingStatus) {
        guard
            let requirement = requirement(id: id),
            !requirement.isMerged,
            requirement.hasMergeRequestURL,
            requirement.mrTrackingStatus != status
        else {
            return
        }

        update(id: id, updatesTimestamp: false) { requirement in
            requirement.mrTrackingStatus = status

            switch status {
            case .created:
                requirement.isMRMergeMonitoringEnabled = false
                requirement.mrMergeReminderPending = false
                requirement.mrMergeNotifiedAt = nil
            case .mergeRequested:
                requirement.isMRMergeMonitoringEnabled = false
                requirement.mrMergeReminderPending = false
                requirement.mrMergeNotifiedAt = nil
            case .merged:
                requirement.isMRMergeMonitoringEnabled = false
                requirement.mrMergeReminderPending = true
                requirement.mrMergeNotifiedAt = nil
            }
        }

        guard lastSaveSucceeded else { return }
        lastNotice = "已更新为\(status.title)"
        if status == .merged {
            deliverPendingMRMergeNotifications()
        }
    }

    func setMRMergeMonitoring(id: Requirement.ID, isEnabled: Bool) {
        guard requirement(id: id)?.mrTrackingStatus == .mergeRequested else {
            return
        }

        update(id: id, updatesTimestamp: false) { requirement in
            requirement.isMRMergeMonitoringEnabled = isEnabled
        }
        guard lastSaveSucceeded else { return }
        lastNotice = isEnabled ? "已创建 MR 合并监听" : "已停止 MR 合并监听"
    }

    func deliverPendingMRMergeNotifications() {
        guard MRMergeNotificationService.shared.isAvailable else {
            return
        }

        let pending = requirements.filter {
            $0.mrMergeReminderPending && $0.mrMergeNotifiedAt == nil
        }
        guard !pending.isEmpty else {
            return
        }

        let notifiedAt = Date()
        let pendingIDs = Set(pending.map(\.id))
        var updated = requirements
        for index in updated.indices where pendingIDs.contains(updated[index].id) {
            updated[index].mrMergeNotifiedAt = notifiedAt
        }
        requirements = updated
        guard lastSaveSucceeded else { return }

        for requirement in pending {
            MRMergeNotificationService.shared.notify(requirement: requirement)
        }
    }

    func delete(id: Requirement.ID) {
        requirements.removeAll { $0.id == id }
        guard lastSaveSucceeded else { return }
        lastNotice = "已删除需求"
    }

    func copyCombined(for id: Requirement.ID, notify: Bool = true) {
        guard
            let requirement = requirement(id: id),
            !requirement.combinedCopyText.isEmpty
        else {
            return
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(requirement.combinedCopyText, forType: .string)

        if notify {
            lastNotice = "已复制名称、Jira 与 MR"
        }
    }

    func copy(_ text: String, notice: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        lastNotice = notice
    }

    func openJira(for id: Requirement.ID) {
        guard let requirement = requirement(id: id) else {
            return
        }
        open(requirement.jiraURL)
    }

    func openMR(for id: Requirement.ID) {
        guard let mrURL = requirement(id: id)?.mrURL else {
            return
        }
        open(mrURL)
    }

    func openDataFolder() {
        save()
        guard lastSaveSucceeded else { return }
        NSWorkspace.shared.activateFileViewerSelecting([dataFileURL])
        lastNotice = "已打开数据文件"
    }

    private func open(_ urlString: String) {
        guard let url = URL(string: urlString) else {
            lastNotice = "链接格式无效"
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func normalizeRequirement(
        _ requirement: inout Requirement,
        now: Date,
        allowsMergedWithoutMR: Bool = false
    ) {
        if requirement.isMerged
            && !requirement.hasMergeRequestURL
            && !allowsMergedWithoutMR {
            requirement.isMerged = false
            lastNotice = "请先填写 MR 地址"
        }

        if requirement.isMerged {
            requirement.isTested = true
            requirement.isDone = true
            requirement.stage = .completed
            requirement.completedAt = requirement.completedAt ?? now
        }

        if requirement.stage != .paused && requirement.stage != .stopped {
            if requirement.isTested {
                requirement.isDone = true
                requirement.stage = .completed
                requirement.completedAt = requirement.completedAt ?? now
            }

            if requirement.stage == .completed {
                requirement.isDone = true
                requirement.completedAt = requirement.completedAt ?? now
            }

            if requirement.isDone {
                requirement.stage = .completed
                requirement.completedAt = requirement.completedAt ?? now
            }
        }

        if !requirement.isDone, requirement.stage == .completed {
            requirement.stage = .active
            requirement.isTested = false
            requirement.isMerged = false
            requirement.completedAt = nil
        }

        if let key = RequirementParser.jiraKey(from: requirement.jiraURL) {
            requirement.jiraKey = key
        }

        requirement.title = requirement.title.trimmingCharacters(in: .whitespacesAndNewlines)
        requirement.normalizeMergeRequestURLs()
        requirement.normalizeMRTracking()
    }

    func reloadAfterExternalUpdate(issueKey: String?) {
        guard loadFromDisk() else {
            return
        }

        if let issueKey, !issueKey.isEmpty {
            lastNotice = "已从外部工具更新 \(issueKey)"
        } else {
            lastNotice = "已从外部工具更新数据"
        }
    }

    private func loadFromDisk() -> Bool {
        do {
            if database == nil {
                database = try RequirementDatabase(url: dataFileURL)
            }
            let decoded = try database!.load()
            isLoadingFromDisk = true
            requirements = decoded
            savedSnapshot = decoded
            isLoadingFromDisk = false
            return true
        } catch {
            isLoadingFromDisk = false
            lastNotice = "读取失败：\(error.localizedDescription)"
            return false
        }
    }

    private func save() {
        lastSaveSucceeded = false
        guard let database else {
            lastNotice = "数据库未成功加载，未保存修改。"
            return
        }
        do {
            let saved = try database.applyChanges(before: savedSnapshot, after: requirements)
            isLoadingFromDisk = true
            requirements = saved
            savedSnapshot = saved
            lastSaveSucceeded = true
            isLoadingFromDisk = false
        } catch {
            let message = error.localizedDescription
            _ = loadFromDisk()
            lastNotice = "保存失败：\(message)"
        }
    }
}

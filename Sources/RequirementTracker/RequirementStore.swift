import AppKit
import Foundation
import RequirementCore

@MainActor
final class RequirementStore: ObservableObject {
    @Published var requirements: [Requirement] = [] {
        didSet {
            guard !isBootstrapping else {
                return
            }
            save()
        }
    }

    let dataFileURL: URL
    @Published var lastNotice: String?

    private var isBootstrapping = true

    init(dataFileURL: URL? = nil) {
        self.dataFileURL = dataFileURL ?? Self.defaultDataFileURL()
        let canSaveAfterLoading = load()

        isBootstrapping = false

        if canSaveAfterLoading {
            save()
        }
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
        lastNotice = "已添加 \(parsed.count) 个需求"
        return parsed.count
    }

    func update(id: Requirement.ID, _ transform: (inout Requirement) -> Void) {
        guard let index = requirements.firstIndex(where: { $0.id == id }) else {
            return
        }

        let now = Date()
        transform(&requirements[index])
        normalizeRequirement(at: index, now: now)
        requirements[index].updatedAt = now
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

            if requirement.stage == .pending {
                requirement.stage = .active
                return
            }

            if requirement.isTested {
                guard requirement.hasMergeRequestURL else {
                    lastNotice = "请先填写 MR 地址"
                    return
                }

                requirement.isMerged = true
                requirement.isDone = true
                requirement.stage = .completed
                requirement.completedAt = Date()
                return
            }

            if requirement.isDone || requirement.stage == .completed {
                requirement.isTested = true
                requirement.isDone = true
                requirement.stage = .completed
                return
            }

            requirement.stage = .completed
            requirement.isDone = true
            requirement.completedAt = Date()
        }
    }

    func delete(id: Requirement.ID) {
        requirements.removeAll { $0.id == id }
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
            lastNotice = "已复制 Jira 与 MR"
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

    private func normalizeRequirement(at index: Int, now: Date) {
        if requirements[index].isMerged && !requirements[index].hasMergeRequestURL {
            requirements[index].isMerged = false
            lastNotice = "请先填写 MR 地址"
        }

        if requirements[index].isMerged {
            requirements[index].isTested = true
            requirements[index].isDone = true
            requirements[index].stage = .completed
            requirements[index].completedAt = requirements[index].completedAt ?? now
        }

        if requirements[index].stage != .paused && requirements[index].stage != .stopped {
            if requirements[index].isTested {
                requirements[index].isDone = true
                requirements[index].stage = .completed
                requirements[index].completedAt = requirements[index].completedAt ?? now
            }

            if requirements[index].stage == .completed {
                requirements[index].isDone = true
                requirements[index].completedAt = requirements[index].completedAt ?? now
            }

            if requirements[index].isDone {
                requirements[index].stage = .completed
                requirements[index].completedAt = requirements[index].completedAt ?? now
            }
        }

        if !requirements[index].isDone, requirements[index].stage == .completed {
            requirements[index].stage = .active
            requirements[index].isTested = false
            requirements[index].isMerged = false
            requirements[index].completedAt = nil
        }

        if let key = RequirementParser.jiraKey(from: requirements[index].jiraURL) {
            requirements[index].jiraKey = key
        }

        requirements[index].mrURL = requirements[index].mrURL?.nilIfBlank
    }

    private func load() -> Bool {
        guard FileManager.default.fileExists(atPath: dataFileURL.path) else {
            return true
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        do {
            let data = try Data(contentsOf: dataFileURL)
            let decoded = try decoder.decode([Requirement].self, from: data)
            requirements = decoded
            return true
        } catch {
            lastNotice = "读取失败：\(error.localizedDescription)"
            return false
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: dataFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

            let data = try encoder.encode(requirements)
            try data.write(to: dataFileURL, options: [.atomic])
        } catch {
            lastNotice = "保存失败：\(error.localizedDescription)"
        }
    }

    private static func defaultDataFileURL() -> URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory

        return applicationSupport
            .appendingPathComponent("RequirementTracker", isDirectory: true)
            .appendingPathComponent("requirements.json")
    }

}

private extension String {
    var nilIfBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

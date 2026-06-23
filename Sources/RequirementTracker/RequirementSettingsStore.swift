import Foundation
import RequirementCore

@MainActor
final class RequirementSettingsStore: ObservableObject {
    @Published var configuration: RequirementToolConfiguration {
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
        configuration = Self.load(from: self.dataFileURL) ?? RequirementToolConfiguration()
        isBootstrapping = false
        save()
    }

    var validScriptProjects: [RequirementScriptProject] {
        configuration.validScriptProjects
    }

    var validQuickLinks: [RequirementQuickLink] {
        configuration.validQuickLinks
    }

    func panelDateSelection(for statusFilter: RequirementStatusFilter) -> RequirementPanelDateSelection {
        configuration.baseSettings.panelFilters.selection(for: statusFilter)
    }

    func setPanelDateSelection(
        _ selection: RequirementPanelDateSelection,
        for statusFilter: RequirementStatusFilter
    ) {
        configuration.baseSettings.panelFilters.setSelection(selection.normalized, for: statusFilter)
    }

    func updatePluginSettings(_ transform: (inout RequirementPluginSettings) -> Void) {
        transform(&configuration.pluginSettings)
    }

    @discardableResult
    func addScriptProject(directoryURL: URL) -> RequirementScriptProject.ID? {
        let normalizedPath = directoryURL.path
        let existingPaths = Set(configuration.scriptProjects.map(\.normalized.directoryPath))
        guard !existingPaths.contains(normalizedPath) else {
            lastNotice = "项目已存在"
            return configuration.scriptProjects.first { $0.normalized.directoryPath == normalizedPath }?.id
        }

        let project = RequirementScriptProject(
            name: directoryURL.lastPathComponent,
            directoryPath: normalizedPath,
            scripts: []
        )
        configuration.scriptProjects.append(project)
        lastNotice = "已添加脚本项目"
        return project.id
    }

    func deleteScriptProject(id: RequirementScriptProject.ID) {
        configuration.scriptProjects.removeAll { $0.id == id }
        lastNotice = "已删除脚本项目"
    }

    func updateScriptProject(id: RequirementScriptProject.ID, _ transform: (inout RequirementScriptProject) -> Void) {
        guard let index = configuration.scriptProjects.firstIndex(where: { $0.id == id }) else {
            return
        }

        transform(&configuration.scriptProjects[index])
    }

    func addScript(to projectID: RequirementScriptProject.ID) {
        updateScriptProject(id: projectID) { project in
            project.scripts.append(
                RequirementScriptCommand(name: "新脚本", script: "")
            )
        }
    }

    func deleteScript(projectID: RequirementScriptProject.ID, scriptID: RequirementScriptCommand.ID) {
        updateScriptProject(id: projectID) { project in
            project.scripts.removeAll { $0.id == scriptID }
        }
    }

    func addQuickLink() {
        configuration.quickLinks.append(
            RequirementQuickLink(name: "新链接", url: "")
        )
    }

    func deleteQuickLink(id: RequirementQuickLink.ID) {
        configuration.quickLinks.removeAll { $0.id == id }
    }

    func updateQuickLink(id: RequirementQuickLink.ID, _ transform: (inout RequirementQuickLink) -> Void) {
        guard let index = configuration.quickLinks.firstIndex(where: { $0.id == id }) else {
            return
        }

        transform(&configuration.quickLinks[index])
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: dataFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(configuration.normalized)
            try data.write(to: dataFileURL, options: [.atomic])
        } catch {
            lastNotice = "设置保存失败：\(error.localizedDescription)"
        }
    }

    private static func load(from url: URL) -> RequirementToolConfiguration? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(RequirementToolConfiguration.self, from: data).normalized
        } catch {
            return nil
        }
    }

    private static func defaultDataFileURL() -> URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory

        return applicationSupport
            .appendingPathComponent("RequirementTracker", isDirectory: true)
            .appendingPathComponent("settings.json")
    }
}

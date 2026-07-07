import Foundation

public struct RequirementToolConfiguration: Codable, Equatable, Sendable {
    public var baseSettings: RequirementBaseSettings
    public var pluginSettings: RequirementPluginSettings
    public var scriptProjects: [RequirementScriptProject]
    public var quickLinks: [RequirementQuickLink]

    public init(
        baseSettings: RequirementBaseSettings = RequirementBaseSettings(),
        pluginSettings: RequirementPluginSettings = RequirementPluginSettings(),
        scriptProjects: [RequirementScriptProject] = [],
        quickLinks: [RequirementQuickLink] = []
    ) {
        self.baseSettings = baseSettings
        self.pluginSettings = pluginSettings
        self.scriptProjects = scriptProjects
        self.quickLinks = quickLinks
    }

    private enum CodingKeys: String, CodingKey {
        case baseSettings
        case pluginSettings
        case scriptProjects
        case quickLinks
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        baseSettings = try container.decodeIfPresent(RequirementBaseSettings.self, forKey: .baseSettings)
            ?? RequirementBaseSettings()
        pluginSettings = try container.decodeIfPresent(RequirementPluginSettings.self, forKey: .pluginSettings)
            ?? RequirementPluginSettings()
        scriptProjects = try container.decodeIfPresent([RequirementScriptProject].self, forKey: .scriptProjects) ?? []
        quickLinks = try container.decodeIfPresent([RequirementQuickLink].self, forKey: .quickLinks) ?? []
    }

    public var validScriptProjects: [RequirementScriptProject] {
        scriptProjects
            .map(\.normalized)
            .filter(\.isValid)
    }

    public var validQuickLinks: [RequirementQuickLink] {
        quickLinks
            .map(\.normalized)
            .filter(\.isValid)
    }

    public var normalized: RequirementToolConfiguration {
        RequirementToolConfiguration(
            baseSettings: baseSettings.normalized,
            pluginSettings: pluginSettings.normalized,
            scriptProjects: scriptProjects.map(\.normalized),
            quickLinks: quickLinks.map(\.normalized)
        )
    }
}

public struct RequirementPluginSettings: Codable, Equatable, Sendable {
    public static let defaultNativeHostName = "com.aderx.requirementtracker.jira_capture"

    public var jiraBaseURL: String
    public var mrHosts: [String]
    public var chromeExtensionID: String

    public init(
        jiraBaseURL: String = RequirementParser.defaultJiraBaseURL,
        mrHosts: [String] = ["gitlab.zstack.io"],
        chromeExtensionID: String = ""
    ) {
        self.jiraBaseURL = jiraBaseURL
        self.mrHosts = mrHosts
        self.chromeExtensionID = chromeExtensionID
    }

    public var validMRHosts: [String] {
        mrHosts.compactMap(Self.normalizedHost(from:)).uniquedPreservingOrder()
    }

    public var normalized: RequirementPluginSettings {
        RequirementPluginSettings(
            jiraBaseURL: Self.normalizedJiraBaseURL(jiraBaseURL),
            mrHosts: validMRHosts,
            chromeExtensionID: chromeExtensionID.trimmed
        )
    }

    private static func normalizedJiraBaseURL(_ value: String) -> String {
        let fallback = RequirementParser.defaultJiraBaseURL
        let trimmed = value.trimmed.isEmpty ? fallback : value.trimmed
        let normalized = RequirementParser.normalizedURL(trimmed)
        guard !normalized.isEmpty else {
            return fallback
        }

        return normalized.hasSuffix("/") ? normalized : "\(normalized)/"
    }

    private static func normalizedHost(from value: String) -> String? {
        let trimmed = value.trimmed
        guard !trimmed.isEmpty else {
            return nil
        }

        let host: String?
        if let parsed = URLComponents(string: trimmed), parsed.scheme != nil {
            host = parsed.host
        } else if let parsed = URLComponents(string: "https://\(trimmed)") {
            host = parsed.host
        } else {
            host = nil
        }

        return host?.lowercased().trimmed.nilIfBlank
    }
}

public struct RequirementBaseSettings: Codable, Equatable, Sendable {
    public var panelFilters: RequirementPanelFilterConfiguration
    public var tabSort: RequirementTabSortConfiguration

    public init(
        panelFilters: RequirementPanelFilterConfiguration = RequirementPanelFilterConfiguration(),
        tabSort: RequirementTabSortConfiguration = RequirementTabSortConfiguration()
    ) {
        self.panelFilters = panelFilters
        self.tabSort = tabSort
    }

    private enum CodingKeys: String, CodingKey {
        case panelFilters
        case tabSort
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        panelFilters = try container.decodeIfPresent(RequirementPanelFilterConfiguration.self, forKey: .panelFilters)
            ?? RequirementPanelFilterConfiguration()
        tabSort = try container.decodeIfPresent(RequirementTabSortConfiguration.self, forKey: .tabSort)
            ?? RequirementTabSortConfiguration()
    }

    public var normalized: RequirementBaseSettings {
        RequirementBaseSettings(
            panelFilters: panelFilters.normalized,
            tabSort: tabSort.normalized
        )
    }
}

/// 单个状态分组的排序规则：`ascending` 为 true 时组内时间早的在前。
public struct RequirementTabSortRule: Codable, Equatable, Sendable, Identifiable {
    public var status: RequirementTimelineStatus
    public var ascending: Bool

    public var id: String { status.rawValue }

    public init(status: RequirementTimelineStatus, ascending: Bool = true) {
        self.status = status
        self.ascending = ascending
    }
}

/// 各状态 TAB 的列表排序配置：状态分组顺序 + 每组时间方向。
/// 默认值与既有排序行为保持一致。
public struct RequirementTabSortConfiguration: Codable, Equatable, Sendable {
    public var incomplete: [RequirementTabSortRule]
    public var active: [RequirementTabSortRule]
    public var pending: [RequirementTabSortRule]
    public var paused: [RequirementTabSortRule]
    public var completed: [RequirementTabSortRule]

    public init(
        incomplete: [RequirementTabSortRule]? = nil,
        active: [RequirementTabSortRule]? = nil,
        pending: [RequirementTabSortRule]? = nil,
        paused: [RequirementTabSortRule]? = nil,
        completed: [RequirementTabSortRule]? = nil
    ) {
        self.incomplete = incomplete ?? Self.defaultRules(for: .incomplete)
        self.active = active ?? Self.defaultRules(for: .active)
        self.pending = pending ?? Self.defaultRules(for: .pending)
        self.paused = paused ?? Self.defaultRules(for: .paused)
        self.completed = completed ?? Self.defaultRules(for: .completed)
    }

    private enum CodingKeys: String, CodingKey {
        case incomplete
        case active
        case pending
        case paused
        case completed
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        incomplete = try container.decodeIfPresent([RequirementTabSortRule].self, forKey: .incomplete)
            ?? Self.defaultRules(for: .incomplete)
        active = try container.decodeIfPresent([RequirementTabSortRule].self, forKey: .active)
            ?? Self.defaultRules(for: .active)
        pending = try container.decodeIfPresent([RequirementTabSortRule].self, forKey: .pending)
            ?? Self.defaultRules(for: .pending)
        paused = try container.decodeIfPresent([RequirementTabSortRule].self, forKey: .paused)
            ?? Self.defaultRules(for: .paused)
        completed = try container.decodeIfPresent([RequirementTabSortRule].self, forKey: .completed)
            ?? Self.defaultRules(for: .completed)
    }

    /// 每个 TAB 实际包含的状态集合（由筛选逻辑决定，顺序可配置、成员不可增删）。
    public static func allowedStatuses(for statusFilter: RequirementStatusFilter) -> [RequirementTimelineStatus] {
        switch statusFilter {
        case .incomplete:
            [.active, .done, .pending, .tested, .paused]
        case .active:
            [.active, .done, .tested]
        case .pending:
            [.pending]
        case .paused:
            [.paused, .stopped]
        case .completed:
            [.merged]
        }
    }

    public static func defaultRules(for statusFilter: RequirementStatusFilter) -> [RequirementTabSortRule] {
        // 异常与已完成 TAB 默认按时间倒序（新的在前），其余按时间正序。
        let ascending = statusFilter != .paused && statusFilter != .completed
        return allowedStatuses(for: statusFilter).map {
            RequirementTabSortRule(status: $0, ascending: ascending)
        }
    }

    public func rules(for statusFilter: RequirementStatusFilter) -> [RequirementTabSortRule] {
        let stored = switch statusFilter {
        case .incomplete:
            incomplete
        case .active:
            active
        case .pending:
            pending
        case .paused:
            paused
        case .completed:
            completed
        }

        return Self.normalizedRules(stored, for: statusFilter)
    }

    public mutating func setRules(
        _ rules: [RequirementTabSortRule],
        for statusFilter: RequirementStatusFilter
    ) {
        let normalized = Self.normalizedRules(rules, for: statusFilter)
        switch statusFilter {
        case .incomplete:
            incomplete = normalized
        case .active:
            active = normalized
        case .pending:
            pending = normalized
        case .paused:
            paused = normalized
        case .completed:
            completed = normalized
        }
    }

    /// 去掉不属于该 TAB 的状态与重复项，缺失的状态按默认规则补到末尾。
    private static func normalizedRules(
        _ rules: [RequirementTabSortRule],
        for statusFilter: RequirementStatusFilter
    ) -> [RequirementTabSortRule] {
        let allowed = allowedStatuses(for: statusFilter)
        var seen = Set<RequirementTimelineStatus>()
        var normalized: [RequirementTabSortRule] = []

        for rule in rules where allowed.contains(rule.status) && !seen.contains(rule.status) {
            seen.insert(rule.status)
            normalized.append(rule)
        }

        for rule in defaultRules(for: statusFilter) where !seen.contains(rule.status) {
            seen.insert(rule.status)
            normalized.append(rule)
        }

        return normalized
    }

    public var normalized: RequirementTabSortConfiguration {
        RequirementTabSortConfiguration(
            incomplete: Self.normalizedRules(incomplete, for: .incomplete),
            active: Self.normalizedRules(active, for: .active),
            pending: Self.normalizedRules(pending, for: .pending),
            paused: Self.normalizedRules(paused, for: .paused),
            completed: Self.normalizedRules(completed, for: .completed)
        )
    }
}

public struct RequirementPanelFilterConfiguration: Codable, Equatable, Sendable {
    public var incomplete: RequirementPanelDateSelection
    public var active: RequirementPanelDateSelection
    public var pending: RequirementPanelDateSelection
    public var paused: RequirementPanelDateSelection
    public var completed: RequirementPanelDateSelection

    public init(
        incomplete: RequirementPanelDateSelection = RequirementPanelDateSelection(),
        active: RequirementPanelDateSelection = RequirementPanelDateSelection(),
        pending: RequirementPanelDateSelection = RequirementPanelDateSelection(),
        paused: RequirementPanelDateSelection = RequirementPanelDateSelection(),
        completed: RequirementPanelDateSelection = RequirementPanelDateSelection()
    ) {
        self.incomplete = incomplete
        self.active = active
        self.pending = pending
        self.paused = paused
        self.completed = completed
    }

    private enum CodingKeys: String, CodingKey {
        case incomplete
        case active
        case pending
        case paused
        case completed
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        incomplete = try container.decodeIfPresent(RequirementPanelDateSelection.self, forKey: .incomplete)
            ?? RequirementPanelDateSelection()
        active = try container.decodeIfPresent(RequirementPanelDateSelection.self, forKey: .active)
            ?? RequirementPanelDateSelection()
        pending = try container.decodeIfPresent(RequirementPanelDateSelection.self, forKey: .pending)
            ?? RequirementPanelDateSelection()
        paused = try container.decodeIfPresent(RequirementPanelDateSelection.self, forKey: .paused)
            ?? RequirementPanelDateSelection()
        completed = try container.decodeIfPresent(RequirementPanelDateSelection.self, forKey: .completed)
            ?? RequirementPanelDateSelection()
    }

    public func selection(for statusFilter: RequirementStatusFilter) -> RequirementPanelDateSelection {
        switch statusFilter {
        case .incomplete:
            incomplete
        case .active:
            active
        case .pending:
            pending
        case .paused:
            paused
        case .completed:
            completed
        }
    }

    public mutating func setSelection(
        _ selection: RequirementPanelDateSelection,
        for statusFilter: RequirementStatusFilter
    ) {
        switch statusFilter {
        case .incomplete:
            incomplete = selection
        case .active:
            active = selection
        case .pending:
            pending = selection
        case .paused:
            paused = selection
        case .completed:
            completed = selection
        }
    }

    public var normalized: RequirementPanelFilterConfiguration {
        RequirementPanelFilterConfiguration(
            incomplete: incomplete.normalized,
            active: active.normalized,
            pending: pending.normalized,
            paused: paused.normalized,
            completed: completed.normalized
        )
    }
}

public struct RequirementPanelDateSelection: Codable, Equatable, Sendable {
    public var dateFilter: RequirementDateFilter
    public var selectedDay: Date?

    public init(
        dateFilter: RequirementDateFilter = .all,
        selectedDay: Date? = nil
    ) {
        self.dateFilter = dateFilter
        self.selectedDay = selectedDay
    }

    public var normalized: RequirementPanelDateSelection {
        RequirementPanelDateSelection(
            dateFilter: selectedDay == nil ? dateFilter : .all,
            selectedDay: dateFilter == .all ? selectedDay : nil
        )
    }
}

public struct RequirementScriptProject: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var directoryPath: String
    public var scripts: [RequirementScriptCommand]

    public init(
        id: UUID = UUID(),
        name: String,
        directoryPath: String,
        scripts: [RequirementScriptCommand] = []
    ) {
        self.id = id
        self.name = name
        self.directoryPath = directoryPath
        self.scripts = scripts
    }

    public var validScripts: [RequirementScriptCommand] {
        scripts
            .map(\.normalized)
            .filter(\.isValid)
    }

    public var normalized: RequirementScriptProject {
        RequirementScriptProject(
            id: id,
            name: name.trimmed,
            directoryPath: directoryPath.trimmed,
            scripts: scripts.map(\.normalized)
        )
    }

    public var isValid: Bool {
        !name.trimmed.isEmpty
            && !directoryPath.trimmed.isEmpty
            && !validScripts.isEmpty
    }
}

public struct RequirementScriptCommand: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var script: String

    public init(
        id: UUID = UUID(),
        name: String,
        script: String
    ) {
        self.id = id
        self.name = name
        self.script = script
    }

    public var normalized: RequirementScriptCommand {
        RequirementScriptCommand(
            id: id,
            name: name.trimmed,
            script: script.trimmed
        )
    }

    public var isValid: Bool {
        !name.trimmed.isEmpty && !script.trimmed.isEmpty
    }
}

public struct RequirementQuickLink: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var url: String

    public init(
        id: UUID = UUID(),
        name: String,
        url: String
    ) {
        self.id = id
        self.name = name
        self.url = url
    }

    public var normalized: RequirementQuickLink {
        RequirementQuickLink(
            id: id,
            name: name.trimmed,
            url: url.trimmed
        )
    }

    public var isValid: Bool {
        guard
            !name.trimmed.isEmpty,
            let url = URL(string: url.trimmed),
            let scheme = url.scheme?.lowercased(),
            !scheme.isEmpty
        else {
            return false
        }

        if scheme == "http" || scheme == "https" {
            return url.host?.isEmpty == false
        }

        return true
    }
}

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var nilIfBlank: String? {
        isEmpty ? nil : self
    }
}

private extension Array where Element: Hashable {
    func uniquedPreservingOrder() -> [Element] {
        var seen = Set<Element>()
        var values: [Element] = []

        for element in self where !seen.contains(element) {
            seen.insert(element)
            values.append(element)
        }

        return values
    }
}

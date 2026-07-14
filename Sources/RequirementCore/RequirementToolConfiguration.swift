import Foundation

public struct RequirementToolConfiguration: Codable, Equatable, Sendable {
    public var baseSettings: RequirementBaseSettings
    public var pluginSettings: RequirementPluginSettings
    public var scriptProjects: [RequirementScriptProject]
    public var quickLinkItems: [RequirementQuickLinkItem]

    public init(
        baseSettings: RequirementBaseSettings = RequirementBaseSettings(),
        pluginSettings: RequirementPluginSettings = RequirementPluginSettings(),
        scriptProjects: [RequirementScriptProject] = [],
        quickLinks: [RequirementQuickLink] = [],
        quickLinkItems: [RequirementQuickLinkItem]? = nil
    ) {
        self.baseSettings = baseSettings
        self.pluginSettings = pluginSettings
        self.scriptProjects = scriptProjects
        self.quickLinkItems = quickLinkItems ?? quickLinks.map(RequirementQuickLinkItem.link)
    }

    private enum CodingKeys: String, CodingKey {
        case baseSettings
        case pluginSettings
        case scriptProjects
        case quickLinks
        case quickLinkItems
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        baseSettings = try container.decodeIfPresent(RequirementBaseSettings.self, forKey: .baseSettings)
            ?? RequirementBaseSettings()
        pluginSettings = try container.decodeIfPresent(RequirementPluginSettings.self, forKey: .pluginSettings)
            ?? RequirementPluginSettings()
        scriptProjects = try container.decodeIfPresent([RequirementScriptProject].self, forKey: .scriptProjects) ?? []
        if let decodedItems = try container.decodeIfPresent([RequirementQuickLinkItem].self, forKey: .quickLinkItems) {
            quickLinkItems = decodedItems
        } else {
            let legacyLinks = try container.decodeIfPresent([RequirementQuickLink].self, forKey: .quickLinks) ?? []
            quickLinkItems = legacyLinks.map(RequirementQuickLinkItem.link)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(baseSettings, forKey: .baseSettings)
        try container.encode(pluginSettings, forKey: .pluginSettings)
        try container.encode(scriptProjects, forKey: .scriptProjects)
        try container.encode(quickLinkItems, forKey: .quickLinkItems)
        // 保留扁平镜像，旧版 App 降级后仍能读取全部链接，只会丢失分组展示。
        try container.encode(quickLinks, forKey: .quickLinks)
    }

    public var validScriptProjects: [RequirementScriptProject] {
        scriptProjects
            .map(\.normalized)
            .filter(\.isValid)
    }

    public var validQuickLinks: [RequirementQuickLink] {
        validQuickLinkItems.flatMap(\.links)
    }

    public var validQuickLinkItems: [RequirementQuickLinkItem] {
        quickLinkItems.compactMap(\.validMenuItem)
    }

    public var quickLinks: [RequirementQuickLink] {
        quickLinkItems.flatMap(\.links)
    }

    public var quickLinkGroups: [RequirementQuickLinkGroup] {
        quickLinkItems.compactMap(\.group)
    }

    @discardableResult
    public mutating func moveScriptProject(
        id: RequirementScriptProject.ID,
        offset: Int
    ) -> Bool {
        guard
            offset != 0,
            let index = scriptProjects.firstIndex(where: { $0.id == id })
        else {
            return false
        }

        let target = index + offset
        guard scriptProjects.indices.contains(target) else {
            return false
        }

        scriptProjects.swapAt(index, target)
        return true
    }

    @discardableResult
    public mutating func moveQuickLinkItem(id: UUID, offset: Int) -> Bool {
        guard
            offset != 0,
            let index = quickLinkItems.firstIndex(where: { $0.id == id })
        else {
            return false
        }

        let target = index + offset
        guard quickLinkItems.indices.contains(target) else {
            return false
        }

        quickLinkItems.swapAt(index, target)
        return true
    }

    @discardableResult
    public mutating func moveQuickLink(id: RequirementQuickLink.ID, offset: Int) -> Bool {
        if let index = quickLinkItems.firstIndex(where: { $0.link?.id == id }) {
            let target = index + offset
            guard quickLinkItems.indices.contains(target) else {
                return false
            }

            quickLinkItems.swapAt(index, target)
            return true
        }

        for itemIndex in quickLinkItems.indices {
            guard var group = quickLinkItems[itemIndex].group,
                  group.moveLink(id: id, offset: offset)
            else {
                continue
            }

            quickLinkItems[itemIndex] = .group(group)
            return true
        }

        return false
    }

    public func quickLink(id: RequirementQuickLink.ID) -> RequirementQuickLink? {
        quickLinkItems.lazy.compactMap { item in
            if let link = item.link, link.id == id {
                return link
            }
            return item.group?.links.first { $0.id == id }
        }.first
    }

    public func quickLinkGroup(id: RequirementQuickLinkGroup.ID) -> RequirementQuickLinkGroup? {
        quickLinkGroups.first { $0.id == id }
    }

    public func quickLinkGroupID(containing linkID: RequirementQuickLink.ID) -> RequirementQuickLinkGroup.ID? {
        quickLinkGroups.first { group in
            group.links.contains { $0.id == linkID }
        }?.id
    }

    @discardableResult
    public mutating func updateQuickLink(
        id: RequirementQuickLink.ID,
        _ transform: (inout RequirementQuickLink) -> Void
    ) -> Bool {
        for itemIndex in quickLinkItems.indices {
            if var link = quickLinkItems[itemIndex].link, link.id == id {
                transform(&link)
                quickLinkItems[itemIndex] = .link(link)
                return true
            }

            guard var group = quickLinkItems[itemIndex].group,
                  let linkIndex = group.links.firstIndex(where: { $0.id == id })
            else {
                continue
            }

            transform(&group.links[linkIndex])
            quickLinkItems[itemIndex] = .group(group)
            return true
        }

        return false
    }

    @discardableResult
    public mutating func updateQuickLinkGroup(
        id: RequirementQuickLinkGroup.ID,
        _ transform: (inout RequirementQuickLinkGroup) -> Void
    ) -> Bool {
        guard let index = quickLinkItems.firstIndex(where: { $0.group?.id == id }),
              var group = quickLinkItems[index].group
        else {
            return false
        }

        transform(&group)
        quickLinkItems[index] = .group(group)
        return true
    }

    @discardableResult
    public mutating func deleteQuickLink(id: RequirementQuickLink.ID) -> Bool {
        removeQuickLink(id: id) != nil
    }

    @discardableResult
    public mutating func moveQuickLink(
        id: RequirementQuickLink.ID,
        toGroupID groupID: RequirementQuickLinkGroup.ID?
    ) -> Bool {
        let currentGroupID = quickLinkGroupID(containing: id)
        guard currentGroupID != groupID else {
            return false
        }
        if let groupID, quickLinkGroup(id: groupID) == nil {
            return false
        }
        guard let link = removeQuickLink(id: id) else {
            return false
        }

        if let groupID,
           let index = quickLinkItems.firstIndex(where: { $0.group?.id == groupID }),
           var group = quickLinkItems[index].group {
            group.links.append(link)
            quickLinkItems[index] = .group(group)
        } else {
            quickLinkItems.append(.link(link))
        }
        return true
    }

    @discardableResult
    public mutating func dissolveQuickLinkGroup(id: RequirementQuickLinkGroup.ID) -> Bool {
        guard let index = quickLinkItems.firstIndex(where: { $0.group?.id == id }),
              let group = quickLinkItems[index].group
        else {
            return false
        }

        quickLinkItems.remove(at: index)
        quickLinkItems.insert(contentsOf: group.links.map(RequirementQuickLinkItem.link), at: index)
        return true
    }

    private mutating func removeQuickLink(id: RequirementQuickLink.ID) -> RequirementQuickLink? {
        for itemIndex in quickLinkItems.indices {
            if let link = quickLinkItems[itemIndex].link, link.id == id {
                quickLinkItems.remove(at: itemIndex)
                return link
            }

            guard var group = quickLinkItems[itemIndex].group,
                  let linkIndex = group.links.firstIndex(where: { $0.id == id })
            else {
                continue
            }

            let link = group.links.remove(at: linkIndex)
            quickLinkItems[itemIndex] = .group(group)
            return link
        }

        return nil
    }

    public var normalized: RequirementToolConfiguration {
        RequirementToolConfiguration(
            baseSettings: baseSettings.normalized,
            pluginSettings: pluginSettings.normalized,
            scriptProjects: scriptProjects.map(\.normalized),
            quickLinkItems: quickLinkItems.map(\.normalized)
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

public enum RequirementPanelStyle: String, CaseIterable, Codable, Identifiable, Sendable {
    case standard = "default"
    case minimal
    case modern

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .standard:
            "默认"
        case .minimal:
            "极简"
        case .modern:
            "现代"
        }
    }
}

public struct RequirementBaseSettings: Codable, Equatable, Sendable {
    public var panelStyle: RequirementPanelStyle
    public var panelFilters: RequirementPanelFilterConfiguration
    public var tabSort: RequirementTabSortConfiguration

    public init(
        panelStyle: RequirementPanelStyle = .standard,
        panelFilters: RequirementPanelFilterConfiguration = RequirementPanelFilterConfiguration(),
        tabSort: RequirementTabSortConfiguration = RequirementTabSortConfiguration()
    ) {
        self.panelStyle = panelStyle
        self.panelFilters = panelFilters
        self.tabSort = tabSort
    }

    private enum CodingKeys: String, CodingKey {
        case panelStyle
        case panelFilters
        case tabSort
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        panelStyle = try container.decodeIfPresent(RequirementPanelStyle.self, forKey: .panelStyle)
            ?? .standard
        panelFilters = try container.decodeIfPresent(RequirementPanelFilterConfiguration.self, forKey: .panelFilters)
            ?? RequirementPanelFilterConfiguration()
        tabSort = try container.decodeIfPresent(RequirementTabSortConfiguration.self, forKey: .tabSort)
            ?? RequirementTabSortConfiguration()
    }

    public var normalized: RequirementBaseSettings {
        RequirementBaseSettings(
            panelStyle: panelStyle,
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

public struct RequirementQuickLinkGroup: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var links: [RequirementQuickLink]

    public init(
        id: UUID = UUID(),
        name: String,
        links: [RequirementQuickLink] = []
    ) {
        self.id = id
        self.name = name
        self.links = links
    }

    public var normalized: RequirementQuickLinkGroup {
        RequirementQuickLinkGroup(
            id: id,
            name: name.trimmed,
            links: links.map(\.normalized)
        )
    }

    public var validLinks: [RequirementQuickLink] {
        links.map(\.normalized).filter(\.isValid)
    }

    @discardableResult
    public mutating func moveLink(id: RequirementQuickLink.ID, offset: Int) -> Bool {
        guard
            offset != 0,
            let index = links.firstIndex(where: { $0.id == id })
        else {
            return false
        }

        let target = index + offset
        guard links.indices.contains(target) else {
            return false
        }

        links.swapAt(index, target)
        return true
    }
}

public enum RequirementQuickLinkItem: Identifiable, Codable, Equatable, Sendable {
    case link(RequirementQuickLink)
    case group(RequirementQuickLinkGroup)

    public var id: UUID {
        switch self {
        case let .link(link):
            link.id
        case let .group(group):
            group.id
        }
    }

    public var link: RequirementQuickLink? {
        guard case let .link(link) = self else {
            return nil
        }
        return link
    }

    public var group: RequirementQuickLinkGroup? {
        guard case let .group(group) = self else {
            return nil
        }
        return group
    }

    public var links: [RequirementQuickLink] {
        switch self {
        case let .link(link):
            [link]
        case let .group(group):
            group.links
        }
    }

    public var normalized: RequirementQuickLinkItem {
        switch self {
        case let .link(link):
            .link(link.normalized)
        case let .group(group):
            .group(group.normalized)
        }
    }

    public var validMenuItem: RequirementQuickLinkItem? {
        switch normalized {
        case let .link(link):
            return link.isValid ? RequirementQuickLinkItem.link(link) : nil
        case let .group(group):
            let links = group.validLinks
            guard !group.name.trimmed.isEmpty, !links.isEmpty else {
                return nil
            }
            return .group(RequirementQuickLinkGroup(id: group.id, name: group.name, links: links))
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case link
        case group
    }

    private enum ItemType: String, Codable {
        case link
        case group
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(ItemType.self, forKey: .type) {
        case .link:
            self = .link(try container.decode(RequirementQuickLink.self, forKey: .link))
        case .group:
            self = .group(try container.decode(RequirementQuickLinkGroup.self, forKey: .group))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .link(link):
            try container.encode(ItemType.link, forKey: .type)
            try container.encode(link, forKey: .link)
        case let .group(group):
            try container.encode(ItemType.group, forKey: .type)
            try container.encode(group, forKey: .group)
        }
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

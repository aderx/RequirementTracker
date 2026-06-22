import Foundation

public struct RequirementToolConfiguration: Codable, Equatable, Sendable {
    public var scriptProjects: [RequirementScriptProject]
    public var quickLinks: [RequirementQuickLink]

    public init(
        scriptProjects: [RequirementScriptProject] = [],
        quickLinks: [RequirementQuickLink] = []
    ) {
        self.scriptProjects = scriptProjects
        self.quickLinks = quickLinks
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
            scriptProjects: scriptProjects.map(\.normalized),
            quickLinks: quickLinks.map(\.normalized)
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
}

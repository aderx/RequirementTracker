import Foundation
import RequirementCore

struct RequirementEpic: Identifiable, Equatable {
    let id: String
    let key: String
    let name: String
}

extension Requirement {
    var epic: RequirementEpic? {
        guard let key = epicKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            return nil
        }
        let normalizedKey = key.uppercased()
        let host = URL(string: epicURL ?? jiraURL)?.host?.lowercased() ?? ""
        let name = epicName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return RequirementEpic(id: "\(host)/\(normalizedKey)", key: normalizedKey, name: name.isEmpty ? normalizedKey : name)
    }

    var epicGroupID: String {
        epic?.id ?? (epicCapturedAt == nil ? "epic-unknown" : "epic-none")
    }
}

struct RequirementEpicGroup: Identifiable {
    let id: String
    let epic: RequirementEpic?
    let requirements: [Requirement]

    var title: String {
        epic?.name ?? (id == "epic-unknown" ? "Epic 待补全" : "未关联 Epic")
    }

    static func groups(in requirements: [Requirement]) -> [Self] {
        var orderedIDs: [String] = []
        var groups: [String: [Requirement]] = [:]
        for requirement in requirements {
            let id = requirement.epicGroupID
            if groups[id] == nil { orderedIDs.append(id) }
            groups[id, default: []].append(requirement)
        }
        return orderedIDs.compactMap { id in
            guard let items = groups[id], let first = items.first else { return nil }
            return Self(id: id, epic: first.epic, requirements: items)
        }
    }
}

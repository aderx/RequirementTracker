import Foundation

public enum RequirementParser {
    public static let defaultJiraBaseURL = "http://jira.zstack.io/browse/"

    public static func jiraKey(from text: String) -> String? {
        jiraKeys(from: text).first
    }

    public static func jiraKeys(from text: String) -> [String] {
        matches(in: text, pattern: #"[A-Z][A-Z0-9]+-\d+"#)
            .map { $0.uppercased() }
            .uniquedPreservingOrder()
    }

    public static func jiraURL(from text: String, jiraKey: String) -> String {
        let urls = urls(from: text)
        if let exact = urls.first(where: { $0.uppercased().contains(jiraKey.uppercased()) }) {
            return normalizedURL(exact)
        }

        return defaultJiraBaseURL + jiraKey.uppercased()
    }

    public static func normalizedURL(_ text: String) -> String {
        let value = cleanURLText(text)
        guard var components = URLComponents(string: value) else {
            return value
        }

        components.query = nil
        components.fragment = nil
        return cleanURLText(components.string ?? value)
    }

    public static func mrIdentifier(from text: String?) -> String? {
        guard let text, !text.isEmpty else {
            return nil
        }

        if let requestNumber = firstCapture(in: text, pattern: #"/merge_requests/(\d+)"#) {
            return "!\(requestNumber)"
        }

        if let bangNumber = firstCapture(in: text, pattern: #"!(\d+)"#) {
            return "!\(bangNumber)"
        }

        return nil
    }

    public static func requirements(fromBulkInput text: String, now: Date = Date()) -> [Requirement] {
        var results: [Requirement] = []
        var seenKeys = Set<String>()

        for line in text.components(separatedBy: .newlines) {
            guard
                let key = jiraKey(from: line),
                !seenKeys.contains(key)
            else {
                continue
            }

            seenKeys.insert(key)
            results.append(
                Requirement(
                    jiraKey: key,
                    jiraURL: jiraURL(from: line, jiraKey: key),
                    createdAt: now,
                    updatedAt: now
                )
            )
        }

        return results
    }

    private static func urls(from text: String) -> [String] {
        matches(in: text, pattern: #"https?://[^\s，,）)\]}]+"#)
            .map(cleanURLText)
            .map(normalizedURL)
    }

    private static func cleanURLText(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: " \n\t\r.,，。;；:：）)]}"))
    }

    private static func matches(in text: String, pattern: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return []
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.matches(in: text, range: range).compactMap { result in
            guard let range = Range(result.range, in: text) else {
                return nil
            }
            return String(text[range])
        }
    }

    private static func firstCapture(in text: String, pattern: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return nil
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard
            let result = expression.firstMatch(in: text, range: range),
            result.numberOfRanges > 1,
            let captureRange = Range(result.range(at: 1), in: text)
        else {
            return nil
        }

        return String(text[captureRange])
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

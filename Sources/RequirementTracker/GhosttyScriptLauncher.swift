import Foundation
import RequirementCore

@MainActor
final class GhosttyScriptLauncher: ObservableObject {
    private var projectWindowIDs: [RequirementScriptProject.ID: String] = [:]

    func launch(
        project: RequirementScriptProject,
        script: RequirementScriptCommand
    ) async throws {
        let source = GhosttyAutomationScript.jxa(
            projectDirectory: project.directoryPath,
            command: script.script,
            knownWindowID: projectWindowIDs[project.id]
        )

        let windowID = try await Self.runJavaScriptForAutomation(source)
        projectWindowIDs[project.id] = windowID.isEmpty ? nil : windowID
    }

    private nonisolated static func runJavaScriptForAutomation(
        _ source: String
    ) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-l", "JavaScript", "-e", source]

            let standardOutput = Pipe()
            let standardError = Pipe()
            process.standardOutput = standardOutput
            process.standardError = standardError

            do {
                try process.run()
            } catch {
                throw GhosttyScriptLauncherError.launchFailed(error.localizedDescription)
            }

            let outputData = standardOutput.fileHandleForReading.readDataToEndOfFile()
            let errorData = standardError.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                let message = String(data: errorData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                throw GhosttyScriptLauncherError.launchFailed(
                    message.isEmpty ? "Ghostty 脚本执行失败" : message
                )
            }

            return String(data: outputData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }.value
    }
}

enum GhosttyScriptLauncherError: LocalizedError {
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case let .launchFailed(message):
            message
        }
    }
}

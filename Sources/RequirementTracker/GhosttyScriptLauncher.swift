import Foundation
import RequirementCore

@MainActor
final class GhosttyScriptLauncher: ObservableObject {
    func launch(
        project: RequirementScriptProject,
        script: RequirementScriptCommand
    ) async throws {
        try await launchWithOpen(
            projectDirectory: project.directoryPath,
            command: script.script
        )
    }

    private nonisolated func launchWithOpen(
        projectDirectory: String,
        command: String
    ) async throws {
        let arguments = GhosttyAutomationScript.openArguments(
            projectDirectory: projectDirectory,
            command: command
        )

        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = arguments

            let errorPipe = Pipe()
            process.standardError = errorPipe

            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                let errorOutput = String(
                    data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8
                ) ?? ""
                let message = errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                throw GhosttyScriptLauncherError.launchFailed(
                    message.isEmpty ? "Ghostty 兜底启动失败" : message
                )
            }
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

import Foundation
import RequirementCore

@MainActor
final class GhosttyScriptLauncher: ObservableObject {
    private var projectWindowIDs: [RequirementScriptProject.ID: String] = [:]

    func launch(
        project: RequirementScriptProject,
        script: RequirementScriptCommand
    ) async throws {
        let existingWindowID = projectWindowIDs[project.id]
        let jxa = GhosttyAutomationScript.jxa(
            projectDirectory: project.directoryPath,
            command: script.script,
            knownWindowID: existingWindowID
        )

        do {
            let windowID = try await runJXA(jxa)
            if !windowID.isEmpty {
                projectWindowIDs[project.id] = windowID
            }
        } catch {
            try await launchWithOpen(
                projectDirectory: project.directoryPath,
                command: script.script
            )
        }
    }

    private nonisolated func runJXA(_ script: String) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-l", "JavaScript", "-e", script]

            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            try process.run()
            process.waitUntilExit()

            let output = String(
                data: outputPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            let errorOutput = String(
                data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""

            guard process.terminationStatus == 0 else {
                let message = errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                throw GhosttyScriptLauncherError.launchFailed(
                    message.isEmpty ? "Ghostty 脚本启动失败" : message
                )
            }

            return output.trimmingCharacters(in: .whitespacesAndNewlines)
        }.value
    }

    private nonisolated func launchWithOpen(
        projectDirectory: String,
        command: String
    ) async throws {
        let shellCommand = GhosttyAutomationScript.shellCommand(
            projectDirectory: projectDirectory,
            command: command
        )

        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = [
                "-na",
                "/Applications/Ghostty.app",
                "--args",
                "--working-directory=\(projectDirectory)",
                "-e",
                "/bin/zsh",
                "-lc",
                shellCommand
            ]

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

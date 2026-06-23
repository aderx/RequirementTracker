import AppKit
import Foundation
import RequirementCore

@MainActor
final class GhosttyScriptLauncher: ObservableObject {
    private var projectProcessIDs: [RequirementScriptProject.ID: pid_t] = [:]

    func launch(
        project: RequirementScriptProject,
        script: RequirementScriptCommand
    ) async throws {
        let input = GhosttyAutomationScript.launchInput(
            projectDirectory: project.directoryPath,
            command: script.script
        )

        if let processID = projectProcessIDs[project.id] {
            do {
                try await launchTab(
                    in: processID,
                    projectDirectory: project.directoryPath,
                    input: input
                )
                return
            } catch {
                projectProcessIDs[project.id] = nil
            }
        }

        let processID = try await launchNewWindow(
            projectDirectory: project.directoryPath,
            input: input
        )
        projectProcessIDs[project.id] = processID
    }

    private func launchNewWindow(
        projectDirectory: String,
        input: String
    ) async throws -> pid_t {
        let inputFileURL = try scriptInputFileURL(
            input: input
        )

        let applicationURL = URL(fileURLWithPath: GhosttyAutomationScript.defaultApplicationPath)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = true
        configuration.arguments = GhosttyAutomationScript.applicationArguments(
            projectDirectory: projectDirectory,
            inputFilePath: inputFileURL.path
        )

        return try await withCheckedThrowingContinuation { continuation in
            NSWorkspace.shared.openApplication(
                at: applicationURL,
                configuration: configuration
            ) { runningApplication, error in
                if let error {
                    continuation.resume(
                        throwing: GhosttyScriptLauncherError.launchFailed(error.localizedDescription)
                    )
                    return
                }

                guard let runningApplication else {
                    continuation.resume(
                        throwing: GhosttyScriptLauncherError.launchFailed("Ghostty 启动后未返回进程")
                    )
                    return
                }

                continuation.resume(returning: runningApplication.processIdentifier)
            }
        }
    }

    private func launchTab(
        in processID: pid_t,
        projectDirectory: String,
        input: String
    ) async throws {
        guard let runningApplication = NSRunningApplication(processIdentifier: processID),
              !runningApplication.isTerminated
        else {
            throw GhosttyScriptLauncherError.launchFailed("Ghostty 项目窗口已关闭")
        }

        runningApplication.activate(options: [.activateIgnoringOtherApps])
        try await sendNewTabAppleEvent(
            to: processID,
            projectDirectory: projectDirectory,
            input: input
        )
    }

    private nonisolated func sendNewTabAppleEvent(
        to processID: pid_t,
        projectDirectory: String,
        input: String
    ) async throws {
        let codes = GhosttyAutomationScript.newTabAppleEventCodes

        try await Task.detached(priority: .userInitiated) {
            let target = NSAppleEventDescriptor(processIdentifier: processID)
            let event = NSAppleEventDescriptor(
                eventClass: AEEventClass(Self.appleEventCode(codes.eventClass)),
                eventID: AEEventID(Self.appleEventCode(codes.eventID)),
                targetDescriptor: target,
                returnID: AEReturnID(kAutoGenerateReturnID),
                transactionID: AETransactionID(kAnyTransactionID)
            )

            let configuration = NSAppleEventDescriptor.record()
            configuration.setDescriptor(
                NSAppleEventDescriptor(string: projectDirectory),
                forKeyword: AEKeyword(Self.appleEventCode(codes.workingDirectoryProperty))
            )
            configuration.setDescriptor(
                NSAppleEventDescriptor(string: input),
                forKeyword: AEKeyword(Self.appleEventCode(codes.initialInputProperty))
            )
            configuration.setDescriptor(
                NSAppleEventDescriptor(boolean: true),
                forKeyword: AEKeyword(Self.appleEventCode(codes.waitAfterCommandProperty))
            )
            event.setParam(
                configuration,
                forKeyword: AEKeyword(Self.appleEventCode(codes.configurationParameter))
            )

            do {
                _ = try event.sendEvent(
                    options: [.waitForReply],
                    timeout: 5
                )
            } catch {
                throw GhosttyScriptLauncherError.launchFailed(error.localizedDescription)
            }
        }.value
    }

    private nonisolated static func appleEventCode(_ value: String) -> UInt32 {
        value.utf8.reduce(UInt32(0)) { code, byte in
            (code << 8) + UInt32(byte)
        }
    }

    private nonisolated func scriptInputFileURL(
        input: String
    ) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RequirementTracker", isDirectory: true)
            .appendingPathComponent("GhosttyInput", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let fileURL = directory.appendingPathComponent("\(UUID().uuidString).txt")
        try input.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
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

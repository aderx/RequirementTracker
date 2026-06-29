import AppKit
import Foundation
import RequirementCore

enum RequirementPluginSupport {
    private static let extensionRelativePath = "Integrations/JiraRequirementCapture/extension"
    private static let installerRelativePath = "Scripts/install-jira-native-host.sh"
    private static let bundledExtensionDirectoryName = "JiraRequirementCaptureExtension"
    private static let bundledNativeHostExecutableName = "JiraRequirementNativeHost"

    static var extensionDirectoryURL: URL? {
        firstExistingURL([
            bundledExtensionDirectoryURL,
            repositoryRootURL()?.appendingPathComponent(extensionRelativePath, isDirectory: true)
        ])
    }

    static var installerScriptURL: URL? {
        repositoryRootURL()?.appendingPathComponent(installerRelativePath)
    }

    static func openExtensionDirectory() throws {
        guard let extensionDirectoryURL,
              FileManager.default.fileExists(atPath: extensionDirectoryURL.path)
        else {
            throw PluginSupportError.missingExtensionDirectory
        }

        NSWorkspace.shared.activateFileViewerSelecting([extensionDirectoryURL])
    }

    static func openChromeExtensionsPage() {
        if let url = URL(string: "chrome://extensions") {
            NSWorkspace.shared.open(url)
        }
    }

    static func installNativeHost(extensionID: String) async throws -> String {
        let extensionID = extensionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !extensionID.isEmpty else {
            throw PluginSupportError.missingExtensionID
        }

        if let bundledNativeHostExecutableURL,
           FileManager.default.fileExists(atPath: bundledNativeHostExecutableURL.path) {
            return try installBundledNativeHost(
                hostExecutableURL: bundledNativeHostExecutableURL,
                extensionID: extensionID
            )
        }

        guard let repositoryRootURL = repositoryRootURL(),
              let installerScriptURL,
              FileManager.default.fileExists(atPath: installerScriptURL.path)
        else {
            throw PluginSupportError.missingInstallerScript
        }

        return try await runInstaller(
            scriptURL: installerScriptURL,
            repositoryRootURL: repositoryRootURL,
            extensionID: extensionID
        )
    }

    private static var bundledExtensionDirectoryURL: URL? {
        Bundle.main.resourceURL?.appendingPathComponent(bundledExtensionDirectoryName, isDirectory: true)
    }

    private static var bundledNativeHostExecutableURL: URL? {
        Bundle.main.resourceURL?.appendingPathComponent(bundledNativeHostExecutableName)
    }

    private static func firstExistingURL(_ candidates: [URL?]) -> URL? {
        let fileManager = FileManager.default
        for candidate in candidates.compactMap({ $0 }) where fileManager.fileExists(atPath: candidate.path) {
            return candidate
        }

        return nil
    }

    private static func repositoryRootURL() -> URL? {
        let candidates = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
            Bundle.main.bundleURL,
            Bundle.main.bundleURL.deletingLastPathComponent(),
            Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
        ]

        for candidate in candidates {
            if let root = nearestRepositoryRoot(from: candidate) {
                return root
            }
        }

        return nil
    }

    private static func installBundledNativeHost(
        hostExecutableURL: URL,
        extensionID: String
    ) throws -> String {
        let manifestDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Google/Chrome/NativeMessagingHosts", isDirectory: true)
        let manifestURL = manifestDirectoryURL
            .appendingPathComponent(RequirementPluginSettings.defaultNativeHostName)
            .appendingPathExtension("json")

        try FileManager.default.createDirectory(
            at: manifestDirectoryURL,
            withIntermediateDirectories: true
        )

        let manifest: [String: Any] = [
            "name": RequirementPluginSettings.defaultNativeHostName,
            "description": "RequirementTracker Jira capture native host",
            "path": hostExecutableURL.path,
            "type": "stdio",
            "allowed_origins": [
                "chrome-extension://\(extensionID)/"
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: manifestURL, options: .atomic)

        return "Installed native messaging host:\n\(manifestURL.path)"
    }

    private static func nearestRepositoryRoot(from startURL: URL) -> URL? {
        var current = startURL.standardizedFileURL
        let fileManager = FileManager.default

        for _ in 0..<8 {
            let extensionURL = current.appendingPathComponent(extensionRelativePath, isDirectory: true)
            let installerURL = current.appendingPathComponent(installerRelativePath)
            if fileManager.fileExists(atPath: extensionURL.path)
                && fileManager.fileExists(atPath: installerURL.path) {
                return current
            }

            let parent = current.deletingLastPathComponent()
            if parent.path == current.path {
                return nil
            }

            current = parent
        }

        return nil
    }

    private static func runInstaller(
        scriptURL: URL,
        repositoryRootURL: URL,
        extensionID: String
    ) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [scriptURL.path, extensionID, "chrome"]
            process.currentDirectoryURL = repositoryRootURL

            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe
            process.terminationHandler = { process in
                let output = String(
                    data: outputPipe.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8
                ) ?? ""
                let error = String(
                    data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8
                ) ?? ""

                if process.terminationStatus == 0 {
                    continuation.resume(returning: output.trimmingCharacters(in: .whitespacesAndNewlines))
                } else {
                    continuation.resume(
                        throwing: PluginSupportError.installFailed(
                            (error.isEmpty ? output : error).trimmingCharacters(in: .whitespacesAndNewlines)
                        )
                    )
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

private enum PluginSupportError: LocalizedError {
    case missingExtensionID
    case missingExtensionDirectory
    case missingInstallerScript
    case installFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingExtensionID:
            "请先填写 Chrome 扩展 ID"
        case .missingExtensionDirectory:
            "未找到浏览器插件目录"
        case .missingInstallerScript:
            "未找到 Native Host 安装脚本"
        case .installFailed(let message):
            message.isEmpty ? "Native Host 安装失败" : message
        }
    }
}

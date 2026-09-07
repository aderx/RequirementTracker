import Foundation

enum DeveloperCommand: String, CaseIterable, Identifiable {
    case zsStart = "zs-start"
    case devServices = "dev-services"

    var id: String { rawValue }

    var summary: String {
        switch self {
        case .zsStart: "ZStack 项目启动"
        case .devServices: "服务与内存"
        }
    }

    var resourceDirectory: String {
        switch self {
        case .zsStart: "ZsStart"
        case .devServices: "DevServices"
        }
    }

    var managerFile: String {
        switch self {
        case .zsStart: "zs_start_manager.py"
        case .devServices: "dev_services_manager.py"
        }
    }

    var registrationNote: String {
        switch self {
        case .zsStart: "注册时备份原命令，卸载时恢复。App 更新后，命令随之更新。"
        case .devServices: "在终端运行 dev-services 查看服务与内存，选择具体进程后确认清理。卸载仅移除本命令。"
        }
    }
}

struct GlobalCommandStatus: Decodable, Sendable {
    let toolVersion: String
    let commandPath: String
    let registrationState: String
    let registrationDetail: String

    var isManaged: Bool {
        registrationState == "installed" || registrationState == "repair"
    }
}

enum GlobalCommandSupport {
    static func run(_ arguments: [String], for command: DeveloperCommand) async throws -> GlobalCommandStatus {
        let scriptURL = try scriptURL(for: command)
        return try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = ["-B", scriptURL.path] + arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let message = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? "命令执行失败"
                throw GlobalCommandSupportError.operationFailed(message)
            }
            return try JSONDecoder().decode(GlobalCommandStatus.self, from: data)
        }.value
    }

    private static func scriptURL(for command: DeveloperCommand) throws -> URL {
        let relativePath = "\(command.resourceDirectory)/\(command.managerFile)"
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent(relativePath),
           FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }
        #if DEVELOPMENT
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let candidates = [
            repository.appendingPathComponent(".build/widget-preview/需求记录 Dev.app/Contents/Resources/\(relativePath)"),
            repository.appendingPathComponent("Integrations/\(relativePath)")
        ]
        if let script = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            return script
        }
        #endif
        throw GlobalCommandSupportError.operationFailed("未找到 \(command.rawValue) 工具，请重新安装需求记录 App。")
    }
}

private enum GlobalCommandSupportError: LocalizedError {
    case operationFailed(String)

    var errorDescription: String? {
        switch self {
        case let .operationFailed(message): message
        }
    }
}

import AppKit
import SwiftUI

struct GlobalCommandRegistrationView: View {
    let command: DeveloperCommand
    @State private var status: GlobalCommandStatus?
    @State private var isWorking = false
    @State private var notice = ""
    @State private var hasError = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsContentCard("全局命令") {
                HStack(spacing: 8) {
                    Image(systemName: "terminal")
                        .foregroundStyle(DesignColor.doing)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(command.rawValue)
                            .font(.system(size: 15, weight: .semibold, design: .monospaced))
                        Text(command.summary)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let status {
                        Text("v\(status.toolVersion)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        Task { await perform(["registration-status"]) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("刷新命令状态")
                    .accessibilityLabel("刷新命令状态")
                    .pointingHandCursor()
                }

                if let status {
                    Label(
                        status.registrationDetail,
                        systemImage: status.registrationState == "installed" ? "checkmark.circle.fill" : "terminal"
                    )
                    .foregroundStyle(status.registrationState == "installed" ? Color.green : Color.secondary)
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)

                    Text(status.commandPath)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 8) {
                        Button(status.isManaged ? "修复命令" : "注册命令") {
                            Task { await perform(["install"], notice: "已注册 \(command.rawValue)，可在终端使用") }
                        }
                        .disabled(status.registrationState == "conflict")
                        .pointingHandCursor(status.registrationState != "conflict")

                        if status.isManaged {
                            Button("卸载命令") {
                                Task { await perform(["uninstall"], notice: command == .zsStart ? "已取消 App 管理；如有原命令，已恢复" : "已卸载 dev-services 命令") }
                            }
                            .pointingHandCursor()
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else {
                    Text(hasError ? "暂时无法读取命令状态，请刷新重试。" : "正在读取命令状态…")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                Text(command.registrationNote)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !notice.isEmpty {
                Text(notice)
                    .font(.system(size: 12))
                    .foregroundStyle(hasError ? Color.red : Color.secondary)
                    .textSelection(.enabled)
            }
        }
        .disabled(isWorking)
        .overlay(alignment: .bottomTrailing) {
            if isWorking { ProgressView().controlSize(.small) }
        }
        .task { await perform(["registration-status"]) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await perform(["registration-status"]) }
        }
    }

    @MainActor
    private func perform(_ arguments: [String], notice successMessage: String? = nil) async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            status = try await GlobalCommandSupport.run(arguments, for: command)
            if let successMessage { notice = successMessage }
            else if hasError { notice = "" }
            hasError = false
        } catch {
            notice = error.localizedDescription
            hasError = true
        }
    }
}

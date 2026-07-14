import AppKit
import EventKit
import Foundation
import WidgetKit

enum CalendarAccessState: Equatable {
    case fullAccess
    case notDetermined
    case denied
    case unavailable
}

@MainActor
final class CalendarAccessManager: ObservableObject {
    @Published private(set) var state: CalendarAccessState = .notDetermined
    @Published private(set) var isRequesting = false
    @Published private(set) var errorMessage: String?

    private let eventStore = EKEventStore()

    init() {
        refresh()
    }

    var statusTitle: String {
        switch state {
        case .fullAccess:
            return "已允许"
        case .notDetermined:
            return "未授权"
        case .denied:
            return "已关闭"
        case .unavailable:
            return "不可用"
        }
    }

    var statusSystemImage: String {
        switch state {
        case .fullAccess:
            return "checkmark.circle.fill"
        case .notDetermined:
            return "questionmark.circle"
        case .denied:
            return "lock.fill"
        case .unavailable:
            return "exclamationmark.triangle.fill"
        }
    }

    var actionTitle: String {
        switch state {
        case .fullAccess:
            return "已允许"
        case .notDetermined:
            return "允许访问"
        case .denied:
            return "打开系统设置"
        case .unavailable:
            return "不可用"
        }
    }

    func refresh() {
        state = Self.state(for: EKEventStore.authorizationStatus(for: .event))
    }

    func performPrimaryAction() {
        switch state {
        case .notDetermined:
            requestAccess()
        case .denied:
            openPrivacySettings()
        case .fullAccess, .unavailable:
            break
        }
    }

    private func requestAccess() {
        guard !isRequesting else {
            return
        }

        isRequesting = true
        errorMessage = nil

        Task {
            do {
                if #available(macOS 14.0, *) {
                    _ = try await eventStore.requestFullAccessToEvents()
                } else {
                    _ = try await requestLegacyAccess()
                }
            } catch {
                errorMessage = "日历授权失败：\(error.localizedDescription)"
            }

            isRequesting = false
            refresh()
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    private func requestLegacyAccess() async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            eventStore.requestAccess(to: .event) { granted, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    private func openPrivacySettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Calendars",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"
        ]

        for candidate in candidates {
            guard let url = URL(string: candidate) else {
                continue
            }
            if NSWorkspace.shared.open(url) {
                return
            }
        }
    }

    private static func state(for authorizationStatus: EKAuthorizationStatus) -> CalendarAccessState {
        if #available(macOS 14.0, *), authorizationStatus == .fullAccess {
            return .fullAccess
        }

        switch authorizationStatus {
        case .authorized:
            return .fullAccess
        case .notDetermined:
            return .notDetermined
        case .denied, .restricted, .writeOnly:
            return .denied
        case .fullAccess:
            return .fullAccess
        @unknown default:
            return .unavailable
        }
    }
}

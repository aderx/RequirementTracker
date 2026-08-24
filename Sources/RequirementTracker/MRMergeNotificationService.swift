import RequirementCore
@preconcurrency import UserNotifications

@MainActor
final class MRMergeNotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = MRMergeNotificationService()

    var isAvailable: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
            && Bundle.main.bundleIdentifier != nil
    }

    private override init() {
        super.init()
    }

    func configure() {
        guard isAvailable else {
            return
        }
        UNUserNotificationCenter.current().delegate = self
    }

    func notify(requirement: Requirement) {
        guard isAvailable else {
            return
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else {
                return
            }

            let content = UNMutableNotificationContent()
            content.title = "MR 已合并"
            let title = requirement.title.trimmingCharacters(in: .whitespacesAndNewlines)
            content.body = title.isEmpty
                ? requirement.jiraKey
                : "\(requirement.jiraKey) · \(title)"
            content.sound = .default
            content.threadIdentifier = "requirementtracker-mr-merge"

            let request = UNNotificationRequest(
                identifier: "mr-merged-\(requirement.id.uuidString)",
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request)
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}

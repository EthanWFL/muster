import MusterCore
import UserNotifications

@MainActor
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    var onOpen: (() -> Void)?

    func start() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func notify(_ call: ToolCall) {
        guard SettingsStore.shared.notificationsEnabled else { return }
        let content = UNMutableNotificationContent()
        content.title = L10n.t("Approval needed")
        content.body = ToolSummary.line(tool: call.tool, input: call.input, cwd: call.cwd, maxLength: 120)
        content.sound = .default
        content.userInfo = ["callID": call.id]
        let request = UNNotificationRequest(identifier: call.id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor [weak self] in self?.onOpen?() }
        completionHandler()
    }
}

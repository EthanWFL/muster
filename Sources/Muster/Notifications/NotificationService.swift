import MusterCore
import UserNotifications

/// 已确认进程关联的会话持续没有新活动时提醒，不宣称任务完成。
/// 只发 agent 名、项目名和分支，不带任何会话内容。
@MainActor
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    /// `swift run` 没有 bundle id，UNUserNotificationCenter 会直接崩
    private var canNotify: Bool { Bundle.main.bundleIdentifier != nil }

    func start() {
        guard canNotify else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func notifyQuiet(_ sessions: [Session]) {
        let settings = SettingsStore.shared
        for session in sessions {
            let text = L10n.t("%@ has no recent activity · %@", session.agent.displayName,
                              session.projectName + (session.branch.map { " (\($0))" } ?? ""))
            if settings.notificationsEnabled, canNotify {
                let content = UNMutableNotificationContent()
                content.title = "Muster"
                content.body = text
                content.sound = .default
                UNUserNotificationCenter.current().add(
                    UNNotificationRequest(identifier: session.key, content: content, trigger: nil))
            }
            Task { _ = await Self.sendFeishu("Muster · " + text) }
        }
    }

    /// 没配 webhook 返回 nil；失败返回原因。机器人若开了「关键词」校验，文本里的 Muster 要能命中。
    /// shortcut: 不支持机器人的「签名校验」，用到时再加 timestamp + sign。
    static func sendFeishu(_ text: String) async -> String? {
        let raw = await MainActor.run { SettingsStore.shared.feishuWebhook }
        guard !raw.isEmpty else { return nil }
        guard let url = URL(string: raw), url.scheme == "https" else { return L10n.t("Webhook must be an https URL.") }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["msg_type": "text", "content": ["text": text]])
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard (body?["code"] as? Int) == 0 else { return (body?["msg"] as? String) ?? L10n.t("Unexpected response.") }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}

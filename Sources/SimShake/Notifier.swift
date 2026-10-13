import Foundation
import UserNotifications

@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    /// `UNUserNotificationCenter` crashes outside an app bundle (e.g. `swift run`), so skip it there.
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : .current()
    }

    func requestAuthorization() {
        guard let center else { return }
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { @Sendable granted, error in
            if let error {
                NSLog("SimShake: notification authorization failed: %@", error.localizedDescription)
            } else if !granted {
                NSLog("SimShake: notifications are not allowed; failures will be silent")
            }
        }
    }

    func post(title: String, subtitle: String?, body: String) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        if let subtitle { content.subtitle = subtitle }
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        center.add(request) { @Sendable error in
            if let error {
                NSLog("SimShake: failed to post notification: %@", error.localizedDescription)
            }
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

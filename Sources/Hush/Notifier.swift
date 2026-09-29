import Foundation
import UserNotifications

/// Silent banners (no sound: you might be mid-call).
enum Notifier {
    /// Notifications need a real .app bundle; `swift run` has none.
    private static var available: Bool { Bundle.main.bundleIdentifier != nil }

    /// Shows banners even while the Settings window makes Hush the active app.
    private static let presenter = Presenter()

    static func requestPermission() {
        guard available else { return }
        UNUserNotificationCenter.current().delegate = presenter
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
    }

    static func post(_ title: String, _ body: String) {
        guard UserDefaults.standard.bool(forKey: SettingsKey.showNotifications) else { return }
        guard available else {
            print("[Hush] \(title): \(body)")
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

private final class Presenter: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }
}

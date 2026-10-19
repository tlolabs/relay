import AppKit
import UserNotifications
import RelayKit

@MainActor enum AttentionService {
    static func requestPermission() async throws -> Bool {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .denied: return false
        case .authorized, .provisional, .ephemeral: return true
        default: break
        }
        return try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
    }
    static func openNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
            NSWorkspace.shared.open(url)
        }
    }
    static func deliver(count: Int) {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "dockBounce") as? Bool ?? true { NSApp.requestUserAttention(.informationalRequest) }
        if defaults.bool(forKey: "attentionSound") { NSSound(named: "Glass")?.play() }
        if defaults.bool(forKey: "openForAttention") { NSApp.activate(ignoringOtherApps: true); NSApp.windows.first(where: { $0.title == "RELAY" })?.makeKeyAndOrderFront(nil) }
        guard defaults.object(forKey: "notifications") as? Bool ?? true else { return }
        let content = UNMutableNotificationContent(); content.title = "RELAY needs review"
        content.body = "\(count) new or updated item(s) need your attention."
        if defaults.bool(forKey: "attentionSound") { content.sound = .default }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

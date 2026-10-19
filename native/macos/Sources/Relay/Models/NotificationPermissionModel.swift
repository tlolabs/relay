import Observation
import UserNotifications

@MainActor @Observable
final class NotificationPermissionModel {
    private(set) var status: UNAuthorizationStatus = .notDetermined
    private(set) var checking = false
    private(set) var error: String?
    @ObservationIgnored private let readStatus: () async -> UNAuthorizationStatus
    @ObservationIgnored private let requestAuthorization: () async throws -> Bool

    init(readStatus: @escaping () async -> UNAuthorizationStatus = {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }, requestAuthorization: @escaping () async throws -> Bool = {
        try await AttentionService.requestPermission()
    }) {
        self.readStatus = readStatus
        self.requestAuthorization = requestAuthorization
    }

    var message: String {
        if let error { return error }
        switch status {
        case .authorized, .provisional, .ephemeral: return "macOS notification permission is enabled."
        case .denied: return "macOS notifications are disabled for RELAY. Enable them in System Settings → Notifications."
        default: return "macOS notification permission has not been requested."
        }
    }

    func refresh() async {
        let next = await readStatus()
        if next != status { error = nil }
        status = next
    }

    func request() async {
        guard !checking else { return }
        checking = true; error = nil
        defer { checking = false }
        do {
            let granted = try await requestAuthorization()
            status = await readStatus()
            // Some transports report a decision before settings reflects it.
            if status == .notDetermined { status = granted ? .authorized : .denied }
        } catch { self.error = "Could not enable notifications: \(error.localizedDescription)" }
    }
}

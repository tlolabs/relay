import XCTest
import UserNotifications
@testable import Relay

@MainActor final class NotificationPermissionTests: XCTestCase {
    func testFirstDecisionDenialAuthorizationAndRevocationAreReflected() async {
        var current: UNAuthorizationStatus = .notDetermined
        var decision = false
        var requests = 0
        let permission = NotificationPermissionModel(readStatus: { current }, requestAuthorization: {
            requests += 1
            current = decision ? .authorized : .denied
            return decision
        })
        await permission.refresh()
        XCTAssertEqual(permission.status, .notDetermined)
        await permission.request()
        XCTAssertEqual(permission.status, .denied)
        XCTAssertTrue(permission.message.contains("System Settings"))
        decision = true
        await permission.request()
        XCTAssertEqual(permission.status, .authorized)
        current = .denied
        await permission.refresh()
        XCTAssertEqual(permission.status, .denied)
        XCTAssertEqual(requests, 2)
    }

    func testPermissionErrorsStayInSettingsFeedback() async {
        struct Failure: Error {}
        var current: UNAuthorizationStatus = .notDetermined
        let permission = NotificationPermissionModel(readStatus: { current }, requestAuthorization: { throw Failure() })
        await permission.request()
        XCTAssertFalse(permission.checking)
        XCTAssertTrue(permission.message.contains("Could not enable notifications"))
        current = .authorized
        await permission.refresh()
        XCTAssertNil(permission.error)
        XCTAssertTrue(permission.message.contains("enabled"))
    }
}

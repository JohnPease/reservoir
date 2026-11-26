import XCTest
@testable import Reservoir

@MainActor
final class NotificationDeepLinkTests: XCTestCase {
    func testURLParsesFromUserInfo() {
        let url = NotificationDeepLink.url(from: ["deepLink": "reservoir://today"])
        XCTAssertEqual(url, URL(string: "reservoir://today"))
        XCTAssertTrue(WidgetDeepLink.isToday(url!))
    }

    func testJunkUserInfoIsNil() {
        XCTAssertNil(NotificationDeepLink.url(from: [:]))
        XCTAssertNil(NotificationDeepLink.url(from: ["deepLink": 42]))
        XCTAssertNil(NotificationDeepLink.url(from: ["deepLink": ""]))
        XCTAssertNil(NotificationDeepLink.url(from: ["other": "reservoir://today"]))
    }

    func testRouterConsumeClearsPending() {
        let router = DeepLinkRouter()
        XCTAssertNil(router.consume())
        router.route(URL(string: "reservoir://today"))
        XCTAssertEqual(router.pending, URL(string: "reservoir://today"))
        XCTAssertEqual(router.consume(), URL(string: "reservoir://today"))
        XCTAssertNil(router.pending)
        XCTAssertNil(router.consume())
    }

    func testRoutingNilKeepsPending() {
        let router = DeepLinkRouter()
        router.route(URL(string: "reservoir://today"))
        router.route(nil)
        XCTAssertNotNil(router.pending)
    }

    func testKeyMatchesLiveClientPayload() {
        XCTAssertEqual(UserNotificationCenterClient.deepLinkUserInfoKey, "deepLink")
    }
}

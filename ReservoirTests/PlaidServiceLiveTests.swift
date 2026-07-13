import XCTest
import LinkKit
@testable import Reservoir

/// Covers `PlaidServiceLive`'s pure/mappable logic — the LinkKit
/// `ExitErrorCode` → app-domain string mapping, and `handleLinkExit`'s
/// cancel-vs-error branching. Per reservoir-adq.6.1's acceptance criteria,
/// the LinkKit SDK session call and the direct-to-Plaid network exchange
/// call are integration-level and intentionally not unit tested here —
/// those are covered by manual verification (see PR notes).
@MainActor
final class PlaidServiceLiveTests: XCTestCase {
    private final class StubKeychain: KeychainServicing {
        func save(_ value: String, for key: String) throws {}
        func read(for key: String) throws -> String? { nil }
        func delete(for key: String) throws {}
    }

    private func makeSUT() -> PlaidServiceLive {
        PlaidServiceLive(keychain: StubKeychain(), urlSession: .shared)
    }

    // MARK: - handleLinkExit

    func test_handleLinkExit_withNilErrorFields_doesNotSetPresentedError() {
        let sut = makeSUT()
        sut.handleLinkExit(errorType: nil, errorCode: nil)
        XCTAssertNil(sut.presentedError)
    }

    func test_handleLinkExit_withNilErrorFields_hidesLinkPresentation() {
        let sut = makeSUT()
        sut.isPresentingLink = true
        sut.handleLinkExit(errorType: nil, errorCode: nil)
        XCTAssertFalse(sut.isPresentingLink)
    }

    func test_handleLinkExit_withNetworkErrorType_setsNetworkCategory() {
        let sut = makeSUT()
        sut.handleLinkExit(errorType: "NETWORK_ERROR", errorCode: nil)
        XCTAssertEqual(sut.presentedError, .network)
    }

    func test_handleLinkExit_withInstitutionErrorType_setsPlaidSideCategory() {
        let sut = makeSUT()
        sut.handleLinkExit(errorType: "INSTITUTION_ERROR", errorCode: "INSTITUTION_DOWN")
        XCTAssertEqual(sut.presentedError, .plaidSide)
    }

    // MARK: - errorType(for:) — ExitErrorCode -> app-domain string mapping

    private func exitError(_ code: ExitErrorCode) -> ExitError {
        ExitError.privateObjCInitializer(
            errorCode: code,
            errorMessage: "test error",
            displayMesssage: nil,
            errorJSON: nil
        )
    }

    func test_errorType_mapsApiError() {
        XCTAssertEqual(
            PlaidServiceLive.errorType(for: exitError(.apiError(.internalServerError))),
            "API_ERROR"
        )
    }

    func test_errorType_mapsAuthError() {
        XCTAssertEqual(
            PlaidServiceLive.errorType(for: exitError(.authError(.verificationExpired))),
            "AUTH_ERROR"
        )
    }

    func test_errorType_mapsInstitutionError() {
        XCTAssertEqual(
            PlaidServiceLive.errorType(for: exitError(.institutionError(.institutionDown))),
            "INSTITUTION_ERROR"
        )
    }

    func test_errorType_mapsItemError() {
        XCTAssertEqual(
            PlaidServiceLive.errorType(for: exitError(.itemError(.itemLoginRequired))),
            "ITEM_ERROR"
        )
    }

    func test_errorType_mapsInvalidInput() {
        XCTAssertEqual(
            PlaidServiceLive.errorType(for: exitError(.invalidInput(.invalidApiKeys))),
            "INVALID_INPUT"
        )
    }

    func test_errorType_mapsInvalidRequest() {
        XCTAssertEqual(
            PlaidServiceLive.errorType(for: exitError(.invalidRequest(.missingFields))),
            "INVALID_REQUEST"
        )
    }

    func test_errorType_mapsRateLimitExceeded() {
        XCTAssertEqual(
            PlaidServiceLive.errorType(for: exitError(.rateLimitExceeded(.accountsLimit))),
            "RATE_LIMIT_EXCEEDED"
        )
    }

    func test_errorType_mapsInternal() {
        XCTAssertEqual(
            PlaidServiceLive.errorType(for: exitError(.internal("some internal message"))),
            "INTERNAL"
        )
    }

    func test_errorType_mapsUnknown_usingItsTypeField() {
        XCTAssertEqual(
            PlaidServiceLive.errorType(for: exitError(.unknown(type: "SOME_NEW_TYPE", code: "SOME_CODE"))),
            "SOME_NEW_TYPE"
        )
    }

    func test_errorType_mapsAssetReportError() {
        XCTAssertEqual(
            PlaidServiceLive.errorType(for: exitError(.assetReportError(.productNotReady))),
            "ASSET_REPORT_ERROR"
        )
    }
}

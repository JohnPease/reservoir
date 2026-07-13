import XCTest
@testable import Reservoir

final class PlaidErrorClassifierTests: XCTestCase {

    // MARK: - Link errors (from LinkKit's onExit)

    func test_linkError_withNetworkErrorType_classifiesAsNetwork() {
        let category = PlaidErrorClassifier.classify(
            .linkError(errorType: "NETWORK_ERROR", errorCode: nil)
        )
        XCTAssertEqual(category, .network)
    }

    func test_linkError_withConnectivityCode_classifiesAsNetwork() {
        let category = PlaidErrorClassifier.classify(
            .linkError(errorType: nil, errorCode: "INTERNET_CONNECTIVITY")
        )
        XCTAssertEqual(category, .network)
    }

    func test_linkError_withTimeoutCode_classifiesAsNetwork() {
        let category = PlaidErrorClassifier.classify(
            .linkError(errorType: "API_ERROR", errorCode: "REQUEST_TIMEOUT")
        )
        XCTAssertEqual(category, .network)
    }

    func test_linkError_isCaseInsensitive() {
        let category = PlaidErrorClassifier.classify(
            .linkError(errorType: "network_error", errorCode: nil)
        )
        XCTAssertEqual(category, .network)
    }

    func test_linkError_institutionError_classifiesAsPlaidSide() {
        let category = PlaidErrorClassifier.classify(
            .linkError(errorType: "INSTITUTION_ERROR", errorCode: "INSTITUTION_DOWN")
        )
        XCTAssertEqual(category, .plaidSide)
    }

    func test_linkError_itemError_classifiesAsPlaidSide() {
        let category = PlaidErrorClassifier.classify(
            .linkError(errorType: "ITEM_ERROR", errorCode: "ITEM_LOGIN_REQUIRED")
        )
        XCTAssertEqual(category, .plaidSide)
    }

    func test_linkError_withNilFields_classifiesAsPlaidSide() {
        let category = PlaidErrorClassifier.classify(
            .linkError(errorType: nil, errorCode: nil)
        )
        XCTAssertEqual(category, .plaidSide)
    }

    func test_linkError_authError_classifiesAsPlaidSide() {
        let category = PlaidErrorClassifier.classify(
            .linkError(errorType: "AUTH_ERROR", errorCode: "INVALID_CREDENTIALS")
        )
        XCTAssertEqual(category, .plaidSide)
    }

    // MARK: - Exchange errors (from the direct-from-device REST call)

    func test_exchangeError_notConnectedToInternet_classifiesAsNetwork() {
        let category = PlaidErrorClassifier.classify(
            .exchangeError(URLError(.notConnectedToInternet))
        )
        XCTAssertEqual(category, .network)
    }

    func test_exchangeError_timedOut_classifiesAsNetwork() {
        let category = PlaidErrorClassifier.classify(
            .exchangeError(URLError(.timedOut))
        )
        XCTAssertEqual(category, .network)
    }

    func test_exchangeError_cannotFindHost_classifiesAsNetwork() {
        let category = PlaidErrorClassifier.classify(
            .exchangeError(URLError(.cannotFindHost))
        )
        XCTAssertEqual(category, .network)
    }

    func test_exchangeError_networkConnectionLost_classifiesAsNetwork() {
        let category = PlaidErrorClassifier.classify(
            .exchangeError(URLError(.networkConnectionLost))
        )
        XCTAssertEqual(category, .network)
    }

    func test_exchangeError_badServerResponse_classifiesAsPlaidSide() {
        let category = PlaidErrorClassifier.classify(
            .exchangeError(URLError(.badServerResponse))
        )
        XCTAssertEqual(category, .plaidSide)
    }

    func test_exchangeError_decodingFailure_classifiesAsPlaidSide() {
        struct DecodingStandIn: Error {}
        let category = PlaidErrorClassifier.classify(
            .exchangeError(DecodingStandIn())
        )
        XCTAssertEqual(category, .plaidSide)
    }

    // MARK: - User-facing copy

    func test_network_userFacingMessage_matchesUXSpec() {
        XCTAssertEqual(
            PlaidErrorCategory.network.userFacingMessage,
            "Couldn't reach the network. Check your connection and try again."
        )
    }

    func test_plaidSide_userFacingMessage_matchesUXSpec() {
        XCTAssertEqual(
            PlaidErrorCategory.plaidSide.userFacingMessage,
            "Couldn't connect to your bank. Try again."
        )
    }
}

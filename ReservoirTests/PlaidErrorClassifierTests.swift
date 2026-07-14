import XCTest
@testable import Reservoir

final class PlaidErrorClassifierTests: XCTestCase {

    // MARK: - Link errors (from LinkKit's onExit)
    //
    // LinkKit's onExit ExitErrorCode taxonomy (apiError, authError,
    // assetReportError, internal, institutionError, itemError, invalidInput,
    // invalidRequest, rateLimitExceeded, unknown) is exclusively
    // Plaid/institution-side — verified against LinkKit 7.0.2's public
    // interface, there is no client-connectivity category. Every .linkError
    // therefore classifies as .plaidSide unconditionally, regardless of what
    // its errorType/errorCode strings happen to contain.

    func test_linkError_withNetworkLikeErrorType_stillClassifiesAsPlaidSide() {
        let category = PlaidErrorClassifier.classify(
            .linkError(errorType: "NETWORK_ERROR", errorCode: nil)
        )
        XCTAssertEqual(category, .plaidSide)
    }

    func test_linkError_withConnectivityLikeCode_stillClassifiesAsPlaidSide() {
        let category = PlaidErrorClassifier.classify(
            .linkError(errorType: nil, errorCode: "INTERNET_CONNECTIVITY")
        )
        XCTAssertEqual(category, .plaidSide)
    }

    func test_linkError_withTimeoutLikeCode_stillClassifiesAsPlaidSide() {
        let category = PlaidErrorClassifier.classify(
            .linkError(errorType: "API_ERROR", errorCode: "REQUEST_TIMEOUT")
        )
        XCTAssertEqual(category, .plaidSide)
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

    // MARK: - Local storage (Keychain save) errors

    func test_localStorageError_classifiesAsLocalStorage() {
        struct KeychainStandIn: Error {}
        let category = PlaidErrorClassifier.classify(
            .localStorageError(KeychainStandIn())
        )
        XCTAssertEqual(category, .localStorage)
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

    func test_localStorage_userFacingMessage_matchesUXSpec() {
        XCTAssertEqual(
            PlaidErrorCategory.localStorage.userFacingMessage,
            "Couldn't save your login. Try again."
        )
    }
}

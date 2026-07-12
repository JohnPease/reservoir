import XCTest
@testable import Reservoir

final class MerchantMatcherTests: XCTestCase {

    func testExactCaseInsensitiveMatchReturnsRuleType() {
        let rule = MerchantRule(merchantName: "Netflix", type: .fixed)
        let result = MerchantMatcher.match(rules: [rule], merchantName: "netflix")
        XCTAssertEqual(result, .fixed)
    }

    func testExactMatchDifferentCasingStillMatches() {
        let rule = MerchantRule(merchantName: "whole foods", type: .variable)
        let result = MerchantMatcher.match(rules: [rule], merchantName: "Whole Foods")
        XCTAssertEqual(result, .variable)
    }

    func testNoMatchingRuleReturnsNil() {
        let rule = MerchantRule(merchantName: "Netflix", type: .fixed)
        let result = MerchantMatcher.match(rules: [rule], merchantName: "Hulu")
        XCTAssertNil(result)
    }

    func testEmptyRulesReturnsNil() {
        let result = MerchantMatcher.match(rules: [], merchantName: "Netflix")
        XCTAssertNil(result)
    }

    func testEmptyMerchantNameReturnsNil() {
        let rule = MerchantRule(merchantName: "Netflix", type: .fixed)
        let result = MerchantMatcher.match(rules: [rule], merchantName: "   ")
        XCTAssertNil(result)
    }

    func testTrimsWhitespaceBeforeMatching() {
        let rule = MerchantRule(merchantName: "Netflix", type: .fixed)
        let result = MerchantMatcher.match(rules: [rule], merchantName: "  Netflix  ")
        XCTAssertEqual(result, .fixed)
    }

    func testSubstringDoesNotMatch() {
        let rule = MerchantRule(merchantName: "Netflix", type: .fixed)
        let result = MerchantMatcher.match(rules: [rule], merchantName: "Netflix Inc")
        XCTAssertNil(result)
    }

    func testFirstMatchingRuleWinsWhenMultipleRulesPresent() {
        let ruleA = MerchantRule(merchantName: "Rent LLC", type: .fixed)
        let ruleB = MerchantRule(merchantName: "Coffee Shop", type: .variable)
        let result = MerchantMatcher.match(rules: [ruleA, ruleB], merchantName: "Coffee Shop")
        XCTAssertEqual(result, .variable)
    }
}

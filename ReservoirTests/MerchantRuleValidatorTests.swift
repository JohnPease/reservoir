import XCTest
@testable import Reservoir

final class MerchantRuleValidatorTests: XCTestCase {

    func testValidNameAndTypePasses() {
        let result = MerchantRuleValidator.validate(merchantName: "Netflix", type: .fixed, existingRules: [])
        XCTAssertTrue(result.isValid)
    }

    func testEmptyMerchantNameFails() {
        let result = MerchantRuleValidator.validate(merchantName: "   ", type: .fixed, existingRules: [])
        XCTAssertNotNil(result.merchantNameError)
    }

    func testNilTypeFailsWithNoSilentDefault() {
        let result = MerchantRuleValidator.validate(merchantName: "Netflix", type: nil, existingRules: [])
        XCTAssertNotNil(result.typeError)
        XCTAssertFalse(result.isValid)
    }

    func testDuplicateMerchantNameCaseInsensitiveFails() {
        let existing = MerchantRule(merchantName: "netflix", type: .fixed)
        let result = MerchantRuleValidator.validate(merchantName: "Netflix", type: .variable, existingRules: [existing])
        XCTAssertNotNil(result.merchantNameError)
    }

    func testNonDuplicateMerchantNamePasses() {
        let existing = MerchantRule(merchantName: "Netflix", type: .fixed)
        let result = MerchantRuleValidator.validate(merchantName: "Hulu", type: .variable, existingRules: [existing])
        XCTAssertNil(result.merchantNameError)
    }

    func testEditingRuleExcludesItselfFromDuplicateCheck() {
        let ruleBeingEdited = MerchantRule(merchantName: "Netflix", type: .fixed)
        let result = MerchantRuleValidator.validate(
            merchantName: "Netflix",
            type: .variable,
            existingRules: [ruleBeingEdited],
            excluding: ruleBeingEdited
        )
        XCTAssertNil(result.merchantNameError)
    }

    func testEditingRuleStillCatchesDuplicateAgainstAnotherRule() {
        let ruleBeingEdited = MerchantRule(merchantName: "Netflix", type: .fixed)
        let otherRule = MerchantRule(merchantName: "Hulu", type: .variable)
        let result = MerchantRuleValidator.validate(
            merchantName: "Hulu",
            type: .variable,
            existingRules: [ruleBeingEdited, otherRule],
            excluding: ruleBeingEdited
        )
        XCTAssertNotNil(result.merchantNameError)
    }
}

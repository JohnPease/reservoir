import XCTest
@testable import Reservoir

final class KeychainServiceTests: XCTestCase {
    /// Each test gets its own `service` namespace so parallel test runs (and
    /// leftover state from a prior failed run) can't interfere with each
    /// other or with the app's real Keychain entries.
    private func makeSUT(function: String = #function) -> KeychainService {
        KeychainService(service: "com.johnpease.Reservoir.tests.\(function)")
    }

    func test_read_returnsNilWhenNothingStored() throws {
        let sut = makeSUT()
        XCTAssertNil(try sut.read(for: "missing-key"))
    }

    func test_saveThenRead_returnsStoredValue() throws {
        let sut = makeSUT()
        defer { try? sut.delete(for: "token") }
        try sut.save("access-token-123", for: "token")
        XCTAssertEqual(try sut.read(for: "token"), "access-token-123")
    }

    func test_saveTwice_overwritesPreviousValue() throws {
        let sut = makeSUT()
        defer { try? sut.delete(for: "token") }
        try sut.save("first-token", for: "token")
        try sut.save("second-token", for: "token")
        XCTAssertEqual(try sut.read(for: "token"), "second-token")
    }

    func test_delete_removesStoredValue() throws {
        let sut = makeSUT()
        try sut.save("access-token-123", for: "token")
        try sut.delete(for: "token")
        XCTAssertNil(try sut.read(for: "token"))
    }

    func test_delete_whenNothingStored_doesNotThrow() {
        let sut = makeSUT()
        XCTAssertNoThrow(try sut.delete(for: "never-stored"))
    }

    func test_saveAndRead_areScopedByKey() throws {
        let sut = makeSUT()
        defer {
            try? sut.delete(for: "key-a")
            try? sut.delete(for: "key-b")
        }
        try sut.save("token-a", for: "key-a")
        try sut.save("token-b", for: "key-b")
        XCTAssertEqual(try sut.read(for: "key-a"), "token-a")
        XCTAssertEqual(try sut.read(for: "key-b"), "token-b")
    }

    func test_differentServiceNamespaces_doNotSeeEachOthersValues() throws {
        let sutA = KeychainService(service: "com.johnpease.Reservoir.tests.namespaceA")
        let sutB = KeychainService(service: "com.johnpease.Reservoir.tests.namespaceB")
        defer {
            try? sutA.delete(for: "token")
            try? sutB.delete(for: "token")
        }

        try sutA.save("token-a", for: "token")
        XCTAssertNil(try sutB.read(for: "token"))
    }
}

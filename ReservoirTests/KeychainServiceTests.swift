import XCTest
@testable import Reservoir

final class KeychainServiceTests: XCTestCase {
    /// Each test gets its own `service` namespace so parallel test runs (and
    /// leftover state from a prior failed run) can't interfere with each
    /// other or with the app's real Keychain entries.
    private func makeSUT(function: String = #function) -> KeychainService {
        KeychainService(service: "com.johnpease.Reservoir.tests.\(function)")
    }

    func test_read_returnsNilWhenNothingStored() async throws {
        let sut = makeSUT()
        let value = try await sut.read(for: "missing-key")
        XCTAssertNil(value)
    }

    func test_saveThenRead_returnsStoredValue() async throws {
        let sut = makeSUT()
        addTeardownBlock { try? await sut.delete(for: "token") }
        try await sut.save("access-token-123", for: "token")
        let value = try await sut.read(for: "token")
        XCTAssertEqual(value, "access-token-123")
    }

    func test_saveTwice_overwritesPreviousValue() async throws {
        let sut = makeSUT()
        addTeardownBlock { try? await sut.delete(for: "token") }
        try await sut.save("first-token", for: "token")
        try await sut.save("second-token", for: "token")
        let value = try await sut.read(for: "token")
        XCTAssertEqual(value, "second-token")
    }

    func test_delete_removesStoredValue() async throws {
        let sut = makeSUT()
        try await sut.save("access-token-123", for: "token")
        try await sut.delete(for: "token")
        let value = try await sut.read(for: "token")
        XCTAssertNil(value)
    }

    func test_delete_whenNothingStored_doesNotThrow() async {
        let sut = makeSUT()
        do {
            try await sut.delete(for: "never-stored")
        } catch {
            XCTFail("Expected delete of a never-stored key not to throw, got \(error)")
        }
    }

    func test_saveAndRead_areScopedByKey() async throws {
        let sut = makeSUT()
        addTeardownBlock {
            try? await sut.delete(for: "key-a")
            try? await sut.delete(for: "key-b")
        }
        try await sut.save("token-a", for: "key-a")
        try await sut.save("token-b", for: "key-b")
        let valueA = try await sut.read(for: "key-a")
        let valueB = try await sut.read(for: "key-b")
        XCTAssertEqual(valueA, "token-a")
        XCTAssertEqual(valueB, "token-b")
    }

    func test_differentServiceNamespaces_doNotSeeEachOthersValues() async throws {
        let sutA = KeychainService(service: "com.johnpease.Reservoir.tests.namespaceA")
        let sutB = KeychainService(service: "com.johnpease.Reservoir.tests.namespaceB")
        addTeardownBlock {
            try? await sutA.delete(for: "token")
            try? await sutB.delete(for: "token")
        }

        try await sutA.save("token-a", for: "token")
        let valueFromB = try await sutB.read(for: "token")
        XCTAssertNil(valueFromB)
    }
}

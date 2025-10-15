import Testing
import Foundation
@testable import TinyStorage

@Suite struct RetrieveOrThrowTests {
  @Test
  func canStoreAndRetrieveBool() throws {
    let storage = try TestHelpers.makeStore()
    storage.store(true, forKey: "test")
    let value = try storage.retrieveOrThrow(type: Bool.self, forKey: "test")
    #expect(value == true)
  }

  @Test
  func canStoreAndRetrieveInt() throws {
    let storage = try TestHelpers.makeStore()
    storage.store(1, forKey: "test")
    let value = try storage.retrieveOrThrow(type: Int.self, forKey: "test")
    #expect(value == 1)
  }

  @Test
  func canStoreAndRetrieveString() throws {
    let storage = try TestHelpers.makeStore()
    storage.store("Hello, world!", forKey: "test")
    let value = try storage.retrieveOrThrow(type: String.self, forKey: "test")
    #expect(value == "Hello, world!")
  }

  @Test
  func retrieveOrThrowReturnsNilIfKeyIsNotFound() throws {
    let storage = try TestHelpers.makeStore()
    let value = try storage.retrieveOrThrow(type: String.self, forKey: "missing")
    #expect(value == nil)
  }

  @Test
  func retrieveOrThrowThrowsIfDataTypeIsIncorrect() throws {
    let storage = try TestHelpers.makeStore()
    storage.store("Hello, world!", forKey: "test")
    #expect {
      try storage.retrieveOrThrow(type: Int.self, forKey: "test")
    } throws: { _ in true }
  }
}

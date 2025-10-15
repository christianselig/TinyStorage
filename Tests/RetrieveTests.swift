import Testing
import Foundation
@testable import TinyStorage

@Suite struct RetrieveTests {
  @Test
  func canStoreAndRetrieveBool() throws {
    let storage = try TestHelpers.makeStore()
    storage.store(true, forKey: "test")
    let value = storage.retrieve(type: Bool.self, forKey: "test")
    #expect(value == true)
  }

  @Test
  func canStoreAndRetrieveInt() throws {
    let storage = try TestHelpers.makeStore()
    storage.store(1, forKey: "test")
    let value = storage.retrieve(type: Int.self, forKey: "test")
    #expect(value == 1)
  }

  @Test
  func canStoreAndRetrieveString() throws {
    let storage = try TestHelpers.makeStore()
    storage.store("Hello, world!", forKey: "test")
    let value = storage.retrieve(type: String.self, forKey: "test")
    #expect(value == "Hello, world!")
  }

  @Test
  func retrieveReturnsNilIfKeyIsNotFound() throws {
    let storage = try TestHelpers.makeStore()
    let value = storage.retrieve(type: String.self, forKey: "missing")
    #expect(value == nil)
  }
}

import Testing
import Foundation
@testable import TinyStorage

class RetrieveOrThrowTests: BaseTest {
  @Test
  func canStoreAndRetrieveBool() throws {
    storage.store(true, forKey: "test")
    let value = try storage.retrieveOrThrow(type: Bool.self, forKey: "test")
    #expect(value == true)
  }

  @Test
  func canStoreAndRetrieveInt() throws {
    storage.store(1, forKey: "test")
    let value = try storage.retrieveOrThrow(type: Int.self, forKey: "test")
    #expect(value == 1)
  }

  @Test
  func canStoreAndRetrieveString() throws {
    storage.store("Hello, world!", forKey: "test")
    let value = try storage.retrieveOrThrow(type: String.self, forKey: "test")
    #expect(value == "Hello, world!")
  }

  @Test
  func retrieveOrThrowReturnsNilIfKeyIsNotFound() throws {
    let value = try storage.retrieveOrThrow(type: String.self, forKey: "test")
    #expect(value == nil)
  }

  @Test
  func retrieveOrThrowThrowsIfDataTypeIsIncorrect() {
    storage.store("Hello, world!", forKey: "test")
    #expect {
      try storage.retrieveOrThrow(type: Int.self, forKey: "test")
    } throws: { _ in
      return true
    }
  } 
}


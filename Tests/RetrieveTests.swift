import Testing
import Foundation
@testable import TinyStorage

class RetrieveTests: BaseTest {
  @Test
  func canStoreAndRetrieveBool() {
    storage.store(true, forKey: "test")
    let value = storage.retrieve(type: Bool.self, forKey: "test")
    #expect(value == true)
  }

  @Test
  func canStoreAndRetrieveInt() {
    storage.store(1, forKey: "test")
    let value = storage.retrieve(type: Int.self, forKey: "test")
    #expect(value == 1)
  }

  @Test
  func canStoreAndRetrieveString() {
    storage.store("Hello, world!", forKey: "test")
    let value = storage.retrieve(type: String.self, forKey: "test")
    #expect(value == "Hello, world!")
  }

  // can't test this due to assertionFailure() in the implementation
  // @Test
  // func retrieveReturnsNilIfKeyIsNotFound() {
  //   let value = storage.retrieve(type: String.self, forKey: "test")
  //   #expect(value == nil)
  // }
}

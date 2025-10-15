import Foundation
import Testing
@testable import TinyStorage

class TypedFetchTests: BaseTest {
  @Test
  func canStoreAndRetrieveBool() {
    storage.store(true, forKey: "test")
    #expect(storage.bool(forKey: "test") == true)
  }

  @Test 
  func returnsFalseIfBoolIsNotFound() {
    #expect(storage.bool(forKey: UUID().uuidString) == false)
  }

  @Test
  func canStoreAndRetrieveInt() {
    storage.store(1, forKey: "test")
    #expect(storage.integer(forKey: "test") == 1)
  }

  @Test
  func returnsZeroIfIntIsNotFound() {
    #expect(storage.integer(forKey: UUID().uuidString) == 0)
  }

  @Test
  func canIncrementStoredInt() {
    storage.store(1, forKey: "test")
    #expect(storage.integer(forKey: "test") == 1)
    #expect(storage.incrementInteger(forKey: "test") == 2)
  }

  @Test
  func willStoreIncrementedIntIfNotFound() {
    #expect(storage.incrementInteger(forKey: "test") == 1)
  }

  @Test
  func canIncrementStoredIntByGivenAmount() {
    storage.store(1, forKey: "test")
    #expect(storage.incrementInteger(forKey: "test", by: 2) == 3)
  }
}

import Foundation
import Testing
@testable import TinyStorage

@Suite struct TypedFetchTests {
  @Test
  func canStoreAndRetrieveBool() throws {
    let storage = try TestHelpers.makeStore()
    storage.store(true, forKey: "test")
    #expect(storage.bool(forKey: "test") == true)
  }

  @Test
  func returnsFalseIfBoolIsNotFound() throws {
    let storage = try TestHelpers.makeStore()
    #expect(storage.bool(forKey: UUID().uuidString) == false)
  }

  @Test
  func canStoreAndRetrieveInt() throws {
    let storage = try TestHelpers.makeStore()
    storage.store(1, forKey: "test")
    #expect(storage.integer(forKey: "test") == 1)
  }

  @Test
  func returnsZeroIfIntIsNotFound() throws {
    let storage = try TestHelpers.makeStore()
    #expect(storage.integer(forKey: UUID().uuidString) == 0)
  }

  @Test
  func canIncrementStoredInt() throws {
    let storage = try TestHelpers.makeStore()
    storage.store(1, forKey: "test")
    #expect(storage.integer(forKey: "test") == 1)
    #expect(storage.incrementInteger(forKey: "test") == 2)
  }

  @Test
  func willStoreIncrementedIntIfNotFound() throws {
    let storage = try TestHelpers.makeStore()
    #expect(storage.incrementInteger(forKey: "test") == 1)
  }

  @Test
  func canIncrementStoredIntByGivenAmount() throws {
    let storage = try TestHelpers.makeStore()
    storage.store(1, forKey: "test")
    #expect(storage.incrementInteger(forKey: "test", by: 2) == 3)
  }

  @Test
  func incrementIntegerInitializesWithCustomDelta() throws {
    let storage = try TestHelpers.makeStore()
    #expect(storage.incrementInteger(forKey: "custom", by: -5) == -5)
    #expect(storage.integer(forKey: "custom") == -5)
  }

  @Test
  func incrementIntegerSupportsNegativeAdjustments() throws {
    let storage = try TestHelpers.makeStore()
    storage.store(10, forKey: "adjust")
    #expect(storage.incrementInteger(forKey: "adjust", by: -3) == 7)
    #expect(storage.integer(forKey: "adjust") == 7)
  }
}

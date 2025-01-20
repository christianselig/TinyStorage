import Foundation
import Testing
@testable import TinyStorage

private enum TestError: Error {
  case failedToEncode
}

private struct BadEncodable: Codable {
  let id: UUID? = nil

  enum CodingKeys: String, CodingKey {
    case id
  }

  func encode(to encoder: Encoder) throws {
    throw TestError.failedToEncode
  }
}

class StoreTests: BaseTest {
  @Test
  func canStoreAndRetrieveBool() {
    storage.store(true, forKey: "test")
    #expect(storage.bool(forKey: "test") == true)
  }

  @Test
  func storingNilRemovesKey() {
    storage.store("Hello, world!", forKey: "test")
    #expect(storage.retrieve(type: String.self, forKey: "test") == "Hello, world!")
    storage.store(nil, forKey: "test")
    #expect(storage.retrieve(type: String.self, forKey: "test") == nil)
  }

  @Test
  func storingFailedEncodableThrowsError() {
    #expect(throws: TestError.failedToEncode) {
      try storage.storeOrThrow(BadEncodable(), forKey: "test")
    }
  }

  @Test
  func callingRemoveWillRemoveKey() {
    storage.store("Hello, world!", forKey: "test")
    #expect(storage.retrieve(type: String.self, forKey: "test") == "Hello, world!")
    storage.remove(key: "test")
    #expect(storage.retrieve(type: String.self, forKey: "test") == nil)
  }

  @Test
  func callingBulkStoreWillStoreMultipleKeys() {
    let items: [String: (any Codable)?] = ["test": "Hello, world!", "test2": 1337]
    storage.bulkStore(items: items)
    #expect(storage.retrieve(type: String.self, forKey: "test") == "Hello, world!")
    #expect(storage.retrieve(type: Int.self, forKey: "test2") == 1337)
  }

  @Test func callingBulkStoreWillSkipKeysIfAlreadyPresent() {
    storage.store("Hello, world!", forKey: "test")
    let items: [String: (any Codable)?] = ["test": "Overwrite content", "test2": 1337]
    storage.bulkStore(items: items, skipKeyIfAlreadyPresent: true)

    #expect(storage.retrieve(type: String.self, forKey: "test") == "Hello, world!")
    #expect(storage.retrieve(type: Int.self, forKey: "test2") == 1337)
  }

  @Test func callingBulkStoreWillOverwriteKeys() {
    storage.store("Hello, world!", forKey: "test")
    let items: [String: (any Codable)?] = ["test": "Overwrite content", "test2": 1337]
    storage.bulkStore(items: items, skipKeyIfAlreadyPresent: false)

    #expect(storage.retrieve(type: String.self, forKey: "test") == "Overwrite content")
    #expect(storage.retrieve(type: Int.self, forKey: "test2") == 1337)
  }

  @Test func callingBulkStoreWillOverwriteKeysByDefault() {
    storage.store("Hello, world!", forKey: "test")
    let items: [String: (any Codable)?] = ["test": "Overwrite content", "test2": 1337]
    storage.bulkStore(items: items)

    #expect(storage.retrieve(type: String.self, forKey: "test") == "Overwrite content")
    #expect(storage.retrieve(type: Int.self, forKey: "test2") == 1337)
  }
}

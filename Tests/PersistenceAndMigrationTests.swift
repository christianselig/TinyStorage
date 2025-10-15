import Foundation
import Testing
@testable import TinyStorage

@Suite struct BulkStoreAndPersistenceTests {
  @Test
  func bulkStoreHandlesNilAndDataAndSkip() throws {
    let storage = try TestHelpers.makeStore()
    storage.store("original", forKey: "keep")
    storage.store("to-remove", forKey: "remove")

    let sampleData = Data([0, 1, 2, 3])
    let items: [String: (any Codable)?] = [
      "keep": "ignored",
      "remove": nil,
      "data": sampleData
    ]

    storage.bulkStore(items: items, skipKeyIfAlreadyPresent: true)

    #expect(storage.retrieve(type: String.self, forKey: "keep") == "original")
    #expect(storage.retrieve(type: String.self, forKey: "remove") == "to-remove")
    #expect(storage.retrieve(type: Data.self, forKey: "data") == sampleData)

    storage.bulkStore(items: ["remove": nil], skipKeyIfAlreadyPresent: false)
    #expect(storage.retrieve(type: String.self, forKey: "remove") == nil)
  }

  @Test
  func bulkStoreOverwritesWhenAllowed() throws {
    let storage = try TestHelpers.makeStore()
    storage.store("original", forKey: "key")

    let items: [String: (any Codable)?] = ["key": "new"]
    storage.bulkStore(items: items, skipKeyIfAlreadyPresent: false)

    #expect(storage.retrieve(type: String.self, forKey: "key") == "new")
  }

  @Test
  func fileContentsRemainValidAfterRapidWrites() async throws {
    let storage = try TestHelpers.makeStore()
    for value in 0..<10 {
      storage.store(value, forKey: "counter")
    }

    let data = try Data(contentsOf: storage.fileURL)
    #expect(!data.isEmpty)

    let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Data]
    #expect(plist?["counter"] != nil)
  }

  @Test
  func corruptedFileGracefullyResets() throws {
    let storage = try TestHelpers.makeStore()
    storage.store("hello", forKey: "phrase")

    try "junk".data(using: .utf8)?.write(to: storage.fileURL, options: .atomic)

    let insideDirectory = storage.fileURL.deletingLastPathComponent().deletingLastPathComponent()
    let reloaded = TinyStorage(insideDirectory: insideDirectory, name: "unit", logger: OSLogTinyStorageLogger())

    #expect(reloaded.retrieve(type: String.self, forKey: "phrase") == nil)
  }

  @Test
  func allKeysReflectCurrentState() throws {
    let storage = try TestHelpers.makeStore()
    storage.store(1, forKey: "a")
    storage.store(2, forKey: "b")
    storage.remove(key: "a")

    let keys = Set(storage.allKeys.map { $0.rawValue })
    #expect(keys == ["b"])
  }
}

@Suite struct MigrationEdgeCaseTests {
  @Test
  func migratesSupportedCollectionsAndSkipsNested() throws {
    let suiteName = "TinyStorage-Tests-\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
      Issue.record("Unable to create UserDefaults suite")
      return
    }
    defer { defaults.removePersistentDomain(forName: suiteName) }

    defaults.set([true, false], forKey: "boolArray")
    defaults.set(["one", "two"], forKey: "stringArray")
    defaults.set([["nested": 1]], forKey: "unsupported")

    let storage = try TestHelpers.makeStore()
    storage.migrate(
      userDefaults: defaults,
      nonBoolKeys: ["stringArray"],
      boolKeys: ["boolArray"],
      overwriteTinyStorageIfConflict: true
    )

    #expect(storage.retrieve(type: [Bool].self, forKey: "boolArray") == [true, false])
    #expect(storage.retrieve(type: [String].self, forKey: "stringArray") == ["one", "two"])
    #expect(storage.retrieve(type: [String: Int].self, forKey: "unsupported") == nil)
  }

  @Test
  func migrateIgnoresNilValues() throws {
    let suiteName = "TinyStorage-Tests-\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
      Issue.record("Unable to create UserDefaults suite")
      return
    }
    defer { defaults.removePersistentDomain(forName: suiteName) }

    defaults.set(nil, forKey: "missing")

    let storage = try TestHelpers.makeStore()
    storage.migrate(
      userDefaults: defaults,
      nonBoolKeys: ["missing"],
      boolKeys: [],
      overwriteTinyStorageIfConflict: true
    )

    #expect(storage.retrieve(type: String.self, forKey: "missing") == nil)
  }

  @Test
  func migrateHandlesLargeDataPayload() throws {
    let suiteName = "TinyStorage-Tests-\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
      Issue.record("Unable to create UserDefaults suite")
      return
    }
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let largeData = Data(repeating: 0xAB, count: 64 * 1024)
    defaults.set(largeData, forKey: "blob")

    let storage = try TestHelpers.makeStore()
    storage.migrate(
      userDefaults: defaults,
      nonBoolKeys: ["blob"],
      boolKeys: [],
      overwriteTinyStorageIfConflict: true
    )

    #expect(storage.retrieve(type: Data.self, forKey: "blob") == largeData)
  }
}

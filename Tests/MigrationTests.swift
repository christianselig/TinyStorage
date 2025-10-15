import Foundation
import Testing
@testable import TinyStorage

private struct TestCodable: Codable, Equatable {
  let id: UUID
}

@Suite struct MigrationTests {
  @Test
  func callingMigrateWillMigrateKeysFromUserDefaults() throws {
    let suiteName = "TinyStorage-MigrationTests-\(UUID().uuidString)"
    guard let userDefaults = UserDefaults(suiteName: suiteName) else {
      Issue.record("Unable to create UserDefaults suite")
      return
    }
    defer { userDefaults.removePersistentDomain(forName: suiteName) }

    userDefaults.set(true, forKey: "test")
    userDefaults.set(1337, forKey: "test2")

    let testCodable = TestCodable(id: UUID())
    userDefaults.set(try JSONEncoder().encode(testCodable), forKey: "test3")

    let storage = try TestHelpers.makeStore()
    storage.migrate(
      userDefaults: userDefaults,
      nonBoolKeys: ["test2", "test3"],
      boolKeys: ["test"],
      overwriteTinyStorageIfConflict: false
    )

    #expect(storage.bool(forKey: "test") == true)
    #expect(storage.retrieve(type: Int.self, forKey: "test2") == 1337)
    #expect(storage.retrieve(type: TestCodable.self, forKey: "test3") == testCodable)
  }

  @Test
  func callingMigrateWillOverwriteKeysWhenRequested() throws {
    let suiteName = "TinyStorage-MigrationTests-\(UUID().uuidString)"
    guard let userDefaults = UserDefaults(suiteName: suiteName) else {
      Issue.record("Unable to create UserDefaults suite")
      return
    }
    defer { userDefaults.removePersistentDomain(forName: suiteName) }

    userDefaults.set(true, forKey: "test")

    let storage = try TestHelpers.makeStore()
    storage.store(false, forKey: "test")
    storage.migrate(
      userDefaults: userDefaults,
      nonBoolKeys: [],
      boolKeys: ["test"],
      overwriteTinyStorageIfConflict: false
    )

    #expect(storage.bool(forKey: "test") == false)
  }

  @Test
  func callingMigrateWillNotOverwriteKeysWhenRequested() throws {
    let suiteName = "TinyStorage-MigrationTests-\(UUID().uuidString)"
    guard let userDefaults = UserDefaults(suiteName: suiteName) else {
      Issue.record("Unable to create UserDefaults suite")
      return
    }
    defer { userDefaults.removePersistentDomain(forName: suiteName) }

    userDefaults.set(true, forKey: "test")

    let storage = try TestHelpers.makeStore()
    storage.store(false, forKey: "test")
    storage.migrate(
      userDefaults: userDefaults,
      nonBoolKeys: [],
      boolKeys: ["test"],
      overwriteTinyStorageIfConflict: true
    )

    #expect(storage.bool(forKey: "test") == true)
  }
}

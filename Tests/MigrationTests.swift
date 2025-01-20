import Foundation
import Testing
@testable import TinyStorage

private struct TestCodable: Codable, Equatable {
  let id: UUID
}

class MigrationTests: BaseTest {
  @Test
  func callingMigrateWillMigrateKeysFromUserDefaults() {
    let userDefaults = UserDefaults.standard
    userDefaults.set(true, forKey: "test")
    userDefaults.set(1337, forKey: "test2")
    
    let testCodable = TestCodable(id: UUID())
    let testCodableData = try! JSONEncoder().encode(testCodable)
    userDefaults.set(testCodableData, forKey: "test3")
    
    storage.migrate(userDefaults: userDefaults, nonBoolKeys: ["test2", "test3"], boolKeys: ["test"], overwriteTinyStorageIfConflict: false)
    
    #expect(storage.bool(forKey: "test") == true)
    #expect(storage.retrieve(type: Int.self, forKey: "test2") == 1337)
    #expect(storage.retrieve(type: TestCodable.self, forKey: "test3") == testCodable)
  }

  @Test
  func callingMigrateWillOverwriteKeysWhenRequested() {
    let userDefaults = UserDefaults.standard
    userDefaults.set(true, forKey: "test")
    
    storage.store(false, forKey: "test")
    storage.migrate(userDefaults: userDefaults, nonBoolKeys: ["test2", "test3"], boolKeys: ["test"], overwriteTinyStorageIfConflict: false)
    
    #expect(storage.bool(forKey: "test") == false)
  }

  @Test
  func callingMigrateWillNotOverwriteKeysWhenRequested() {
    let userDefaults = UserDefaults.standard
    userDefaults.set(true, forKey: "test")
    
    storage.store(false, forKey: "test")
    storage.migrate(userDefaults: userDefaults, nonBoolKeys: ["test2", "test3"], boolKeys: ["test"], overwriteTinyStorageIfConflict: true)
    
    #expect(storage.bool(forKey: "test") == true)
  }
}

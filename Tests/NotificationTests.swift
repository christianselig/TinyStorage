import Foundation
import Testing
@testable import TinyStorage

@Suite struct NotificationTests {

  @Test
  @MainActor
  func storeEmitsNotificationForChangedValue() async throws {
    let storage = try TestHelpers.makeStore()
    var receivedKeys: [[String]] = []

    let observer = NotificationCenter.default.addObserver(
      forName: TinyStorage.didChangeNotification,
      object: storage,
      queue: .main
    ) { note in
      if let keys = note.userInfo?[TinyStorage.changedKeysUserInfoKey] as? [String] {
        Task { @MainActor in
          receivedKeys.append(keys)
        }
      }
    }
    defer { NotificationCenter.default.removeObserver(observer) }

    storage.store("value", forKey: "key1")

    let notified = await TestHelpers.waitUntil(timeout: TestHelpers.notificationTimeout) { !receivedKeys.isEmpty }
    #expect(notified)
    #expect(receivedKeys.first?.contains("key1") == true)
  }

  @Test
  @MainActor
  func storeDoesNotNotifyOnNoOpWrite() async throws {
    let storage = try TestHelpers.makeStore()
    storage.store("value", forKey: "key1") // initial write (will notify)

    let targetWriteID = UUID().uuidString
    var receivedTargetWriteID = false
    let observer = NotificationCenter.default.addObserver(
      forName: TinyStorage.didChangeNotification,
      object: storage,
      queue: .main
    ) { note in
      if let writeID = note.userInfo?[TinyStorage.writeIDUserInfoKey] as? String,
         writeID == targetWriteID {
        Task { @MainActor in
          receivedTargetWriteID = true
        }
      }
    }
    defer { NotificationCenter.default.removeObserver(observer) }

    // No-op write; bytes are identical
    storage.store("value", forKey: "key1", writeID: targetWriteID)

    let notified = await TestHelpers.waitUntil(timeout: TestHelpers.notificationTimeout) { receivedTargetWriteID }
    #expect(notified == false)
  }

  @Test
  @MainActor
  func bulkStoreSkipsNoOpNotifications() async throws {
    let storage = try TestHelpers.makeStore()
    storage.store("value", forKey: "keep")

    let targetWriteID = UUID().uuidString
    var receivedTargetWriteID = false
    let observer = NotificationCenter.default.addObserver(
      forName: TinyStorage.didChangeNotification,
      object: storage,
      queue: .main
    ) { note in
      if let writeID = note.userInfo?[TinyStorage.writeIDUserInfoKey] as? String,
         writeID == targetWriteID {
        Task { @MainActor in
          receivedTargetWriteID = true
        }
      }
    }
    defer { NotificationCenter.default.removeObserver(observer) }

    storage.bulkStore(items: ["keep": "value"], skipKeyIfAlreadyPresent: false, writeID: targetWriteID)

    let notified = await TestHelpers.waitUntil(timeout: TestHelpers.notificationTimeout) { receivedTargetWriteID }
    #expect(notified == false)
  }

  @Test
  @MainActor
  func migrateDoesNotNotifyOnIdenticalValues() async throws {
    let suiteName = "TinyStorage-NotificationTests-\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
      Issue.record("Unable to create UserDefaults suite")
      return
    }
    defer { defaults.removePersistentDomain(forName: suiteName) }

    defaults.set(true, forKey: "flag")
    defaults.set(42, forKey: "number")

    let storage = try TestHelpers.makeStore()
    storage.store(true, forKey: "flag")
    storage.store(42, forKey: "number")

    let targetWriteID = UUID().uuidString
    var receivedTargetWriteID = false
    let observer = NotificationCenter.default.addObserver(
      forName: TinyStorage.didChangeNotification,
      object: storage,
      queue: .main
    ) { note in
      if let writeID = note.userInfo?[TinyStorage.writeIDUserInfoKey] as? String,
         writeID == targetWriteID {
        Task { @MainActor in
          receivedTargetWriteID = true
        }
      }
    }
    defer { NotificationCenter.default.removeObserver(observer) }

    storage.migrate(
      userDefaults: defaults,
      nonBoolKeys: ["number"],
      boolKeys: ["flag"],
      overwriteTinyStorageIfConflict: true,
      writeID: targetWriteID
    )

    let notified = await TestHelpers.waitUntil(timeout: TestHelpers.notificationTimeout) { receivedTargetWriteID }
    #expect(notified == false)
  }

  @Test
  @MainActor
  func migrateNotifiesWhenValueDiffers() async throws {
    let suiteName = "TinyStorage-NotificationTests-\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
      Issue.record("Unable to create UserDefaults suite")
      return
    }
    defer { defaults.removePersistentDomain(forName: suiteName) }

    defaults.set(false, forKey: "flag")

    let storage = try TestHelpers.makeStore()
    storage.store(true, forKey: "flag") // different from defaults

    var receivedKeys: [[String]] = []
    let observer = NotificationCenter.default.addObserver(
      forName: TinyStorage.didChangeNotification,
      object: storage,
      queue: .main
    ) { note in
      if let keys = note.userInfo?[TinyStorage.changedKeysUserInfoKey] as? [String] {
        Task { @MainActor in
          receivedKeys.append(keys)
        }
      }
    }
    defer { NotificationCenter.default.removeObserver(observer) }

    storage.migrate(
      userDefaults: defaults,
      nonBoolKeys: [],
      boolKeys: ["flag"],
      overwriteTinyStorageIfConflict: true
    )

    let notified = await TestHelpers.waitUntil(timeout: TestHelpers.notificationTimeout) { !receivedKeys.isEmpty }
    #expect(notified)
    #expect(receivedKeys.first?.contains("flag") == true)
  }
}

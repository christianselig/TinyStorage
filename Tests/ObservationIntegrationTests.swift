import Foundation
import Observation
import Testing
@testable import TinyStorage

@Suite struct ObservationIntegrationTests {
  @Test @MainActor
  func autoUpdatingRetrieveTriggersChange() async throws {
    let storage = try TestHelpers.makeStore()

    var observedChange = false
    withObservationTracking {
      _ = storage.autoUpdatingRetrieve(type: Int.self, forKey: "count") ?? 0
    } onChange: {
      MainActor.assumeIsolated {
        observedChange = true
      }
    }

    storage.store(1, forKey: "count")

    let didChange = await TestHelpers.waitUntil(timeout: TestHelpers.notificationTimeout) { observedChange }
    #expect(didChange, "Timed out waiting for auto-updating retrieve to fire change callback")
    #expect(observedChange)
  }

  @Test @MainActor
  func propertyWrapperReflectsStorageUpdates() async throws {
    let storage = try TestHelpers.makeStore()

    @TinyStorageItem(wrappedValue: 0, "score", storage: storage)
    var score: Int

    #expect(score == 0)
    #expect(storage.retrieve(type: Int.self, forKey: "score") == nil)

    score = 5
    #expect(storage.retrieve(type: Int.self, forKey: "score") == 5)

    var changeTriggered = false
    withObservationTracking {
      _ = score
    } onChange: {
      MainActor.assumeIsolated {
        changeTriggered = true
      }
    }

    storage.store(42, forKey: "score")

    let didChange = await TestHelpers.waitUntil(timeout: TestHelpers.notificationTimeout) { changeTriggered }
    #expect(didChange, "Timed out waiting for property wrapper observation to trigger")
    #expect(score == 42)
  }

  @Test @MainActor
  func didChangeNotificationEmittedOncePerWrite() async throws {
    let storage = try TestHelpers.makeStore()

    var count = 0
    let token = NotificationCenter.default.addObserver(
      forName: TinyStorage.didChangeNotification,
      object: storage,
      queue: nil
    ) { _ in
      MainActor.assumeIsolated {
        count += 1
      }
    }

    defer { NotificationCenter.default.removeObserver(token) }

    storage.store("hi", forKey: "greeting")

    let received = await TestHelpers.waitUntil(timeout: TestHelpers.notificationTimeout) { count > 0 }
    #expect(received, "Timed out waiting for change notification")
    #expect(count == 1, "Expected exactly one notification, received \(count)")
  }
}

import Foundation
import Testing
@testable import TinyStorage

enum TimeoutError: Error {
  case exceeded
}

struct TestHelpers {
  static let notificationTimeout: TimeInterval = 0.5
  static let fileWatchTimeout: TimeInterval = 1.0
  static let defaultPollInterval: Duration = .milliseconds(10)

  static func makeStore(fileManager: FileManager = .default) throws -> TinyStorage {
    let base = fileManager.temporaryDirectory.appendingPathComponent("TinyStorageTests", isDirectory: true)
    try fileManager.createDirectory(at: base, withIntermediateDirectories: true)
    let dir = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
    return TinyStorage(insideDirectory: dir, name: "unit", logger: OSLogTinyStorageLogger())
  }

  @MainActor
  static func waitUntil(timeout: TimeInterval, poll: Duration = defaultPollInterval, condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
      if Date() >= deadline {
        return false
      }
      try? await Task.sleep(for: poll)
    }
    return true
  }
}

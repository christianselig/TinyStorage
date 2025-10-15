import Foundation
import Testing
@testable import TinyStorage

@Suite struct ConcurrencyAndReentrancyTests {
    @Test
    func concurrentStoresAndRetrievesComplete() async throws {
        let storage = try TestHelpers.makeStore()
        let iterations = 100
        
        try await withThrowingTaskGroup(of: Void.self) { group in
            for value in 0..<iterations {
                group.addTask {
                    storage.store(value, forKey: "key-\(value % 4)")
                }
                group.addTask {
                    _ = try? storage.retrieveOrThrow(type: Int.self, forKey: "key-\(value % 4)")
                }
            }
            try await group.waitForAll()
        }
        
        let final = storage.retrieve(type: Int.self, forKey: "key-0")
        #expect(final != nil)
    }
    
    @Test
    func incrementIntegerIsAtomicAcrossTasks() async throws {
        let storage = try TestHelpers.makeStore()
        let increments = 200
        
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<increments {
                group.addTask {
                    _ = storage.incrementInteger(forKey: "counter")
                }
            }
            try await group.waitForAll()
        }
        
        let snapshot = storage.integer(forKey: "counter")
        #expect(snapshot == increments, "Expected \(increments) but saw \(snapshot)")
        #expect(storage.incrementInteger(forKey: "counter") == increments + 1)
    }
    
    @Test @MainActor
    func notificationObserverReadingDuringWriteDoesNotDeadlock() async throws {
        let storage = try TestHelpers.makeStore()
        
        var received = false
        let token = NotificationCenter.default.addObserver(
            forName: TinyStorage.didChangeNotification,
            object: storage,
            queue: nil
        ) { _ in
            _ = storage.retrieve(type: String.self, forKey: "value")
            MainActor.assumeIsolated {
                received = true
            }
        }
        
        defer { NotificationCenter.default.removeObserver(token) }
        
        storage.store("hello", forKey: "value")
        
        let didReceive = await TestHelpers.waitUntil(timeout: TestHelpers.notificationTimeout) { received }
        #expect(didReceive, "Timed out waiting for notification while reading during write")
        #expect(received)
    }
    
    @Test @MainActor
    func multiInstanceFileWatchPropagatesSingleChange() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("TinyStorage-MultiInstance", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        
        let storageA = TinyStorage(insideDirectory: base, name: "shared", logger: OSLogTinyStorageLogger())
        let storageB = TinyStorage(insideDirectory: base, name: "shared", logger: OSLogTinyStorageLogger())
        
        var notificationCount = 0
        let token = NotificationCenter.default.addObserver(
            forName: TinyStorage.didChangeNotification,
            object: storageB,
            queue: nil
        ) { _ in
            MainActor.assumeIsolated {
                notificationCount += 1
            }
        }
        
        defer { NotificationCenter.default.removeObserver(token) }
        
        storageA.store("world", forKey: "greeting")
        
        let didObserve = await TestHelpers.waitUntil(timeout: TestHelpers.fileWatchTimeout) { notificationCount > 0 }
        #expect(didObserve, "Timed out waiting for file watcher notification")
        #expect(notificationCount == 1, "Expected exactly one notification, received \(notificationCount)")
        
        #expect(storageB.retrieve(type: String.self, forKey: "greeting") == "world")
    }
}

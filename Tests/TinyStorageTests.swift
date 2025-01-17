import Foundation
import Testing

@testable import TinyStorage

class TinyStorageTests: BaseTest {
  @Test
  func storageFileIsCreatedOnInit() {
    #expect(FileManager.default.fileExists(atPath: storage.fileURL.path()))
  }

  @Test
  func accessDoesNotDeadlock() {
    withObservationTracking { [storage] in
      //storage.bool(forKey: "test")
      storage.store(true, forKey: "test")
    } onChange: { [storage] in
      #expect(storage.bool(forKey: "test") == true)
    }
  }
}

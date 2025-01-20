import Foundation
import Testing

@testable import TinyStorage

class TinyStorageTests: BaseTest {
  @Test
  func storageFileIsCreatedOnInit() {
    #expect(FileManager.default.fileExists(atPath: storage.fileURL.path()))
  }

  @Test
  func callingResetWillRemoveStorageFile() {
    storage.store("Hello, world!", forKey: "test")
    #expect(FileManager.default.fileExists(atPath: storage.fileURL.path()))
    storage.reset()
    #expect(FileManager.default.fileExists(atPath: storage.fileURL.path()) == false )
  }
}

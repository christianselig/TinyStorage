import Foundation
import Testing
@testable import TinyStorage

@Suite struct TinyStorageTests {
  @Test
  func storageFileIsCreatedOnInit() throws {
    let storage = try TestHelpers.makeStore()
    #expect(FileManager.default.fileExists(atPath: storage.fileURL.path()))
  }

  @Test
  func callingResetWillRemoveStorageFile() throws {
    let storage = try TestHelpers.makeStore()
    storage.store("Hello, world!", forKey: "test")
    #expect(FileManager.default.fileExists(atPath: storage.fileURL.path()))
    storage.reset()
    #expect(FileManager.default.fileExists(atPath: storage.fileURL.path()) == false)
  }
}

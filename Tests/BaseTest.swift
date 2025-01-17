import Testing
import Foundation
@testable import TinyStorage

@MainActor
class BaseTest {
  let storage = TinyStorage(insideDirectory: URL.temporaryDirectory, name: UUID().uuidString)

  deinit {
    //storage.reset()
  }
}

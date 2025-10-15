import Testing
import Foundation
@testable import TinyStorage

struct SampleData: Codable, Equatable {
  let id: UUID
}

@Suite struct CodableTests {
  @Test
  func canStoreAndRetrieveCodable() throws {
    let storage = try TestHelpers.makeStore()
    let sampleData = SampleData(id: UUID())
    storage.store(sampleData, forKey: "test")
    let retrievedData = storage.retrieve(type: SampleData.self, forKey: "test")
    #expect(retrievedData == sampleData)
  }
}

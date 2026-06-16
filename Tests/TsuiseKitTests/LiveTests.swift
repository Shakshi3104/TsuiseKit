import Testing
import Foundation
@testable import TsuiseKit

// Live network tests. Disabled by default to keep `swift test` offline.
// Run with: RUN_LIVE=1 swift test --filter Live
@Suite("Live network", .enabled(if: ProcessInfo.processInfo.environment["RUN_LIVE"] == "1"))
struct LiveTests {

    @Test("Japan Post live fetch")
    func japanPostLive() async throws {
        let info = try await JapanPostTracker().fetch(trackingNumber: "3236-8598-1205")
        #expect(info.carrier == .japanPost)
        #expect(!info.events.isEmpty)
        #expect(!info.currentStatus.isEmpty)
        print("[JapanPost] status=\(info.currentStatus), events=\(info.events.count), itemType=\(info.itemType ?? "-")")
    }

    @Test("Yamato live fetch")
    func yamatoLive() async throws {
        let info = try await YamatoTracker().fetch(trackingNumber: "3902-1220-8072")
        #expect(info.carrier == .yamato)
        #expect(!info.events.isEmpty)
        #expect(!info.currentStatus.isEmpty)
        print("[Yamato] status=\(info.currentStatus), events=\(info.events.count), itemType=\(info.itemType ?? "-"), eta=\(info.estimatedDelivery ?? "-")")
    }

    @Test("Sagawa live fetch")
    func sagawaLive() async throws {
        let info = try await SagawaTracker().fetch(trackingNumber: "368054290310")
        #expect(info.carrier == .sagawa)
        #expect(!info.events.isEmpty)
        #expect(!info.currentStatus.isEmpty)
        print("[Sagawa] status=\(info.currentStatus), events=\(info.events.count), eta=\(info.estimatedDelivery ?? "-")")
    }
}

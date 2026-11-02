import Testing
import Foundation
@testable import TsuiseKit

private enum Fixtures {
    static let names = [
        "japanpost_3236.html",
        "yamato_3902.html",
        "sagawa_369024.txt",
    ]

    static var allPresent: Bool {
        names.allSatisfy {
            Bundle.module.url(forResource: $0, withExtension: nil, subdirectory: "Fixtures") != nil
        }
    }
}

@Suite(
    "TsuiseKit parsers",
    .enabled(if: Fixtures.allPresent,
             "Fixtures missing — see Tests/TsuiseKitTests/Fixtures/README.md to regenerate")
)
struct TsuiseKitTests {

    private func loadFixture(_ name: String) throws -> String {
        let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
        let resolved = try #require(url, "Fixture not found: \(name)")
        return try String(contentsOf: resolved, encoding: .utf8)
    }

    @Test("Japan Post parses tracking number 3236-8598-1205")
    func japanPost() throws {
        let html = try loadFixture("japanpost_3236.html")
        let info = try JapanPostTracker().parse(html: html, trackingNumber: "3236-8598-1205")

        #expect(info.carrier == .japanPost)
        #expect(info.trackingNumber == "3236-8598-1205")
        #expect(info.itemType == "ゆうパケット")
        #expect(info.currentStatus == "持ち出し中")
        #expect(info.events.count == 2)

        let first = info.events.first!
        #expect(first.status == "引受")
        #expect(first.rawDate == "2026/06/15 12:10")
        #expect(first.location == "新東京郵便局(楽天)" || first.location == "新東京郵便局(楽天)" || first.location?.contains("新東京郵便局") == true)

        let last = info.events.last!
        #expect(last.status == "持ち出し中")
        #expect(last.location == "高輪郵便局")
    }

    @Test("Yamato parses tracking number 3902-1220-8072")
    func yamato() throws {
        let html = try loadFixture("yamato_3902.html")
        let info = try YamatoTracker().parse(html: html, trackingNumber: "3902-1220-8072")

        #expect(info.carrier == .yamato)
        #expect(info.itemType == "宅急便")
        #expect(info.estimatedDelivery == "06/16 08:00-12:00")
        #expect(info.events.count == 7)

        let first = info.events.first!
        #expect(first.status == "荷物受付")
        #expect(first.rawDate == "06/11 15:57")
        #expect(first.location == "行方営業所")

        #expect(info.currentStatus == "依頼受付(置き場所変更)" || info.currentStatus.contains("置き場所変更"))
    }

    @Test("Sagawa parses tracking number 369024282351")
    func sagawa() throws {
        let payload = try loadFixture("sagawa_369024.txt")
        let info = try SagawaTracker().parse(html: payload, trackingNumber: "369024282351")

        #expect(info.carrier == .sagawa)
        #expect(info.currentStatus == "集荷")
        #expect(info.estimatedDelivery == "11月03日")
        #expect(info.events.count == 1)

        let first = info.events.first!
        #expect(first.status == "集荷")
        #expect(first.rawDate == "10/28 17:00")
        #expect(first.location == "茨城営業所")
    }
}

// Inline payloads with no real tracking data, so these run without fixtures.
@Suite("Sagawa server action payload")
struct SagawaPayloadTests {

    @Test("Sagawa reports an unknown tracking number as notFound")
    func sagawaNotFound() throws {
        let payload = """
        0:{"a":"$@1","q":"","i":false,"b":"x"}
        1:{"ok":true,"results":[{"trackingNumber":"000000000001","status":"該当なし","messageLines":[],"dateLines":[],"shippedDate":"","pickupOffice":null,"deliveryOffice":null,"packageCount":"","history":[]}]}
        """
        #expect(throws: TsuiseKitError.notFound) {
            try SagawaTracker().parse(html: payload, trackingNumber: "000000000001")
        }
    }

    @Test("Sagawa surfaces a failed search as parseFailure")
    func sagawaFailure() throws {
        let payload = """
        0:{"a":"$@1","q":"","i":false,"b":"x"}
        1:{"ok":false,"message":"エラーが発生しました。"}
        """
        #expect(throws: TsuiseKitError.parseFailure(reason: "エラーが発生しました。")) {
            try SagawaTracker().parse(html: payload, trackingNumber: "369024282351")
        }
    }
}

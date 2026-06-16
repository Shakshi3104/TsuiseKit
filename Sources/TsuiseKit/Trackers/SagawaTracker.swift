import Foundation
import SwiftSoup

public struct SagawaTracker: Tracker {
    public let carrier: Carrier = .sagawa

    public init() {}

    public func fetch(trackingNumber: String) async throws -> TrackingInfo {
        guard let url = URL(string: "https://k2k.sagawa-exp.co.jp/p/web/okurijosearch.do") else {
            throw TsuiseKitError.invalidTrackingNumber
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = "okurijoNo=\(trackingNumber)".data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw TsuiseKitError.networkFailure(statusCode: http.statusCode)
        }
        guard let html = String(data: data, encoding: .utf8) else {
            throw TsuiseKitError.parseFailure(reason: "Invalid encoding")
        }
        return try parse(html: html, trackingNumber: trackingNumber)
    }

    public func parse(html: String, trackingNumber: String) throws -> TrackingInfo {
        let doc = try SwiftSoup.parse(html)

        // Status table: <table class="table_basic ttl02"> has <th>s = [詳細N, trackingNumber, currentStatus]
        // and a single <td> containing the message + delivery estimate.
        var currentStatus = ""
        var estimatedDelivery: String? = nil
        let statusTables = try doc.select("table.ttl02")
        if let statusTable = statusTables.first() {
            let ths = try statusTable.select("th").array().map {
                try $0.text().trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if ths.count >= 3 { currentStatus = ths[2] }

            if let td = try statusTable.select("td").first() {
                let raw = try td.text().trimmingCharacters(in: .whitespacesAndNewlines)
                estimatedDelivery = Self.extractValue(after: "配達予定日", from: raw)
            }
        }

        // Events table: <table class="table_okurijo_detail2"> whose header contains
        // 荷物状況, 日時, 担当営業所. There may be multiple table_okurijo_detail2 — pick the right one.
        var events: [TrackingEvent] = []
        for table in try doc.select("table.table_okurijo_detail2") {
            let headerText = try table.select("th").array().map { try $0.text() }.joined()
            guard headerText.contains("荷物状況") && headerText.contains("担当営業所") else { continue }
            for row in try table.select("tr") {
                let cells = try row.select("td")
                guard cells.size() >= 3 else { continue }
                let statusRaw = try cells.get(0).text().trimmingCharacters(in: .whitespacesAndNewlines)
                let dateRaw   = try cells.get(1).text().trimmingCharacters(in: .whitespacesAndNewlines)
                let branch    = try cells.get(2).text().trimmingCharacters(in: .whitespacesAndNewlines)
                let status = statusRaw.trimmingCharacters(in: CharacterSet(charactersIn: "↓⇒ \u{3000}"))
                if status.isEmpty && dateRaw.isEmpty { continue }
                events.append(TrackingEvent(
                    rawDate: dateRaw,
                    date: parseDate(dateRaw),
                    status: status,
                    location: branch.isEmpty ? nil : branch
                ))
            }
            break
        }

        guard !events.isEmpty else {
            throw TsuiseKitError.notFound
        }

        if currentStatus.isEmpty {
            currentStatus = events.last?.status ?? ""
        }

        return TrackingInfo(
            trackingNumber: trackingNumber,
            carrier: .sagawa,
            itemType: nil,
            currentStatus: currentStatus,
            estimatedDelivery: estimatedDelivery,
            events: events
        )
    }

    private static func extractValue(after label: String, from text: String) -> String? {
        guard let range = text.range(of: label) else { return nil }
        let after = text[range.upperBound...]
        // Skip ": ：  " etc., then take rest
        let trimChars = CharacterSet(charactersIn: ": ：　\t\n")
        let value = String(after).trimmingCharacters(in: trimChars)
        return value.isEmpty ? nil : value
    }

    private func parseDate(_ raw: String) -> Date? {
        let cal = Calendar(identifier: .gregorian)
        let year = cal.component(.year, from: Date())
        let df = DateFormatter()
        df.dateFormat = "yyyy/MM/dd HH:mm"
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(identifier: "Asia/Tokyo")
        return df.date(from: "\(year)/\(raw)")
    }
}

private let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

import Foundation
import SwiftSoup

public struct JapanPostTracker: Tracker {
    public let carrier: Carrier = .japanPost

    public init() {}

    public func fetch(trackingNumber: String) async throws -> TrackingInfo {
        var components = URLComponents(string: "https://trackings.post.japanpost.jp/services/srv/search/direct")!
        components.queryItems = [
            URLQueryItem(name: "reqCodeNo1", value: trackingNumber),
            URLQueryItem(name: "searchKind", value: "S004"),
            URLQueryItem(name: "locale", value: "ja"),
        ]
        guard let url = components.url else {
            throw TsuiseKitError.invalidTrackingNumber
        }
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

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
        let tables = try doc.select("table.tableType01")
        guard tables.size() >= 2 else {
            throw TsuiseKitError.notFound
        }

        var itemType: String? = nil
        let headerCells = try tables.get(0).select("tbody td")
        if headerCells.size() >= 2 {
            let text = try headerCells.get(1).text().trimmingCharacters(in: .whitespacesAndNewlines)
            itemType = text.isEmpty ? nil : text
        }

        let rows = try tables.get(1).select("tbody tr")
        var events: [TrackingEvent] = []
        for row in rows {
            let cells = try row.select("td")
            guard cells.size() >= 4 else { continue }
            let rawDate  = try cells.get(0).text().trimmingCharacters(in: .whitespacesAndNewlines)
            let status   = try cells.get(1).text().trimmingCharacters(in: .whitespacesAndNewlines)
            let location = try cells.get(3).text().trimmingCharacters(in: .whitespacesAndNewlines)
            if rawDate.isEmpty && status.isEmpty { continue }
            events.append(TrackingEvent(
                rawDate: rawDate,
                date: parseDate(rawDate),
                status: status,
                location: location.isEmpty ? nil : location
            ))
        }

        guard !events.isEmpty else {
            throw TsuiseKitError.notFound
        }

        return TrackingInfo(
            trackingNumber: trackingNumber,
            carrier: .japanPost,
            itemType: itemType,
            currentStatus: events.last?.status ?? "",
            estimatedDelivery: nil,
            events: events
        )
    }

    private func parseDate(_ raw: String) -> Date? {
        for fmt in ["yyyy/MM/dd HH:mm", "yyyy/MM/dd"] {
            let df = DateFormatter()
            df.dateFormat = fmt
            df.locale = Locale(identifier: "en_US_POSIX")
            df.timeZone = TimeZone(identifier: "Asia/Tokyo")
            if let d = df.date(from: raw) { return d }
        }
        return nil
    }
}

private let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

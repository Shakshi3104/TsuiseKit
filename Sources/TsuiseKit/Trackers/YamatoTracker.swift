import Foundation
import SwiftSoup

public struct YamatoTracker: Tracker {
    public let carrier: Carrier = .yamato

    public init() {}

    public func fetch(trackingNumber: String) async throws -> TrackingInfo {
        guard let url = URL(string: "https://toi.kuronekoyamato.co.jp/cgi-bin/tneko") else {
            throw TsuiseKitError.invalidTrackingNumber
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let body = "number00=1&number01=\(trackingNumber)"
        request.httpBody = body.data(using: .utf8)

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
        let reconstructed = Self.reconstructHTML(from: html)
        guard !reconstructed.isEmpty else {
            throw TsuiseKitError.parseFailure(reason: "No swd.writeln content")
        }

        // The reconstructed string contains <!DOCTYPE>, <html>, <body>, and content after
        // </html>. parseBodyFragment is more lenient and keeps everything as body content.
        let doc = try SwiftSoup.parseBodyFragment(reconstructed)
        let tables = try doc.select("table")

        var events: [TrackingEvent] = []
        for table in tables {
            let headerText = try table.select("th").array().map { try $0.text() }.joined()
            guard headerText.contains("荷物状況") && headerText.contains("担当店名") else { continue }
            for row in try table.select("tr") {
                let cells = try row.select("td")
                guard cells.size() >= 4 else { continue }
                let status   = try cells.get(0).text().trimmingCharacters(in: .whitespacesAndNewlines)
                let dateStr  = try cells.get(1).text().trimmingCharacters(in: .whitespacesAndNewlines)
                let timeStr  = try cells.get(2).text().trimmingCharacters(in: .whitespacesAndNewlines)
                let branch   = try cells.get(3).text().trimmingCharacters(in: .whitespacesAndNewlines)
                let rawDate  = [dateStr, timeStr].filter { !$0.isEmpty }.joined(separator: " ")
                if rawDate.isEmpty && status.isEmpty { continue }
                events.append(TrackingEvent(
                    rawDate: rawDate,
                    date: parseDate(rawDate),
                    status: status,
                    location: branch.isEmpty ? nil : branch
                ))
            }
            break
        }

        guard !events.isEmpty else {
            throw TsuiseKitError.notFound
        }

        // Summary table: headers = 商品名 | お届け予定日時 | お届け希望日時; first data row has the values.
        var itemType: String? = nil
        var estimated: String? = nil
        for table in tables {
            let ths = try table.select("th").array().map { try $0.text() }
            guard ths.contains(where: { $0.contains("商品名") }),
                  let deliveryIndex = ths.firstIndex(where: { $0.contains("お届け予定日時") }),
                  let itemIndex = ths.firstIndex(where: { $0.contains("商品名") })
            else { continue }
            let rows = try table.select("tr")
            for row in rows {
                let cells = try row.select("td")
                guard cells.size() >= max(itemIndex, deliveryIndex) + 1 else { continue }
                let item = try cells.get(itemIndex).text().trimmingCharacters(in: .whitespacesAndNewlines)
                let est  = try cells.get(deliveryIndex).text().trimmingCharacters(in: .whitespacesAndNewlines)
                if !item.isEmpty { itemType = item }
                if !est.isEmpty {
                    // Normalize full-width space (used between date and time range) to regular space
                    estimated = est.replacingOccurrences(of: "\u{3000}", with: " ")
                }
                break
            }
            break
        }

        return TrackingInfo(
            trackingNumber: trackingNumber,
            carrier: .yamato,
            itemType: itemType,
            currentStatus: events.last?.status ?? "",
            estimatedDelivery: estimated,
            events: events
        )
    }

    private static func reconstructHTML(from html: String) -> String {
        let pattern = #"swd\.writeln\('([^']*)'\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return "" }
        let ns = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: ns.length))
        let raw = matches.compactMap { match -> String? in
            guard match.numberOfRanges >= 2 else { return nil }
            return ns.substring(with: match.range(at: 1))
        }.joined()

        // The original JS source escapes HTML-significant chars (\<, \>, \/) so the
        // embedded markup is hidden from the page's own parser. Undo those before
        // feeding the result to SwiftSoup, otherwise <!-- ... --\> stays open as a
        // comment and swallows the actual tables that come after </html>.
        var cleaned = raw
            .replacingOccurrences(of: "\\<", with: "<")
            .replacingOccurrences(of: "\\>", with: ">")
            .replacingOccurrences(of: "\\/", with: "/")
        let strip = [
            #"<!DOCTYPE[^>]*>"#,
            #"</?html[^>]*>"#,
            #"</?head[^>]*>"#,
            #"</?body[^>]*>"#,
            #"<title[^>]*>[\s\S]*?</title>"#,
            #"<style[^>]*>[\s\S]*?</style>"#,
            #"<script[^>]*>[\s\S]*?</script>"#,
            #"<!--[\s\S]*?-->"#,
        ]
        for p in strip {
            cleaned = cleaned.replacingOccurrences(
                of: p,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        return cleaned
    }

    private func parseDate(_ raw: String) -> Date? {
        let cal = Calendar(identifier: .gregorian)
        let year = cal.component(.year, from: Date())
        for fmt in ["yyyy/MM/dd HH:mm", "yyyy/MM/dd"] {
            let df = DateFormatter()
            df.dateFormat = fmt
            df.locale = Locale(identifier: "en_US_POSIX")
            df.timeZone = TimeZone(identifier: "Asia/Tokyo")
            if let d = df.date(from: "\(year)/\(raw)") { return d }
        }
        return nil
    }
}

private let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

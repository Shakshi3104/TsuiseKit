import Foundation
import SwiftSoup

/// Sagawa has been switching its tracking between two sites:
///
/// - **Legacy** `k2k.sagawa-exp.co.jp/p/web/okurijosearch.do` — a form POST answering
///   Windows-31J HTML (`table.ttl02` + `table.table_okurijo_detail2`).
/// - **e-customer** `e-customer.sagawa-exp.co.jp/k2k` — a Next.js app whose search form
///   submits a server action (`searchPackages`) answering a React Server Components payload
///   whose result row is plain JSON.
///
/// Whichever one is down at the moment either serves a maintenance notice or redirects to
/// the other, so `fetch` tries the legacy site first and falls back to e-customer.
public struct SagawaTracker: Tracker {
    public let carrier: Carrier = .sagawa

    public init() {}

    public func fetch(trackingNumber: String) async throws -> TrackingInfo {
        do {
            return try await searchLegacy(trackingNumber: trackingNumber)
        } catch TsuiseKitError.notFound {
            throw TsuiseKitError.notFound
        } catch {
            return try await searchECustomer(trackingNumber: trackingNumber)
        }
    }

    /// Dispatches on the payload: an RSC stream (`0:{...}` rows) from e-customer, HTML otherwise.
    public func parse(html: String, trackingNumber: String) throws -> TrackingInfo {
        if html.drop(while: \.isWhitespace).hasPrefix("0:") {
            return try parseActionPayload(html, trackingNumber: trackingNumber)
        }
        return try parseLegacyHTML(html, trackingNumber: trackingNumber)
    }

    // MARK: - Legacy k2k site

    private func searchLegacy(trackingNumber: String) async throws -> TrackingInfo {
        var request = URLRequest(url: legacyURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let number = trackingNumber.replacingOccurrences(of: "-", with: "")
        request.httpBody = Data("okurijoNo=\(number)".utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw TsuiseKitError.networkFailure(statusCode: http.statusCode)
        }
        // The page declares Windows-31J but writes Japanese as numeric character references,
        // so it is usually plain ASCII; the maintenance notice is raw Shift_JIS.
        guard let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .shiftJIS) else {
            throw TsuiseKitError.parseFailure(reason: "Invalid encoding")
        }
        return try parseLegacyHTML(html, trackingNumber: trackingNumber)
    }

    private func parseLegacyHTML(_ html: String, trackingNumber: String) throws -> TrackingInfo {
        let doc = try SwiftSoup.parse(html)

        // Status table: <table class="table_basic ttl02"> has <th>s = [詳細N, trackingNumber, currentStatus]
        // and a single <td> containing the message + delivery estimate.
        guard let statusTable = try doc.select("table.ttl02").first() else {
            // Maintenance notice or redirect target — not a result page at all.
            throw TsuiseKitError.parseFailure(reason: "Legacy result page unavailable")
        }
        var currentStatus = ""
        let ths = try statusTable.select("th").array().map {
            try $0.text().trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if ths.count >= 3 { currentStatus = ths[2] }
        var estimatedDelivery: String?
        if let td = try statusTable.select("td").first() {
            estimatedDelivery = Self.extractValue(after: "配達予定日", from: try td.text())
        }

        // Events table: the table_okurijo_detail2 whose header has 荷物状況 / 日時 / 担当営業所.
        var events: [TrackingEvent] = []
        for table in try doc.select("table.table_okurijo_detail2") {
            let headerText = try table.select("th").array().map { try $0.text() }.joined()
            guard headerText.contains("荷物状況") && headerText.contains("担当営業所") else { continue }
            for row in try table.select("tr") {
                let cells = try row.select("td")
                guard cells.size() >= 3 else { continue }
                if let event = makeEvent(
                    status: try cells.get(0).text(),
                    date: try cells.get(1).text(),
                    office: try cells.get(2).text()
                ) {
                    events.append(event)
                }
            }
            break
        }

        // "該当なし" (no such parcel) still renders the status table, just without history.
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
        let value = text[range.upperBound...]
            .trimmingCharacters(in: CharacterSet(charactersIn: ": ：　\t\n"))
        return value.isEmpty ? nil : value
    }

    // MARK: - e-customer site

    private func searchECustomer(trackingNumber: String) async throws -> TrackingInfo {
        let cached = await SagawaActionID.shared.current
        do {
            return try await search(trackingNumber: trackingNumber, actionID: cached)
        } catch TsuiseKitError.notFound {
            throw TsuiseKitError.notFound
        } catch {
            // The action ID is a build hash; a redeploy invalidates it. Rediscover once and retry.
            guard let fresh = try? await Self.discoverActionID(), fresh != cached else { throw error }
            await SagawaActionID.shared.update(fresh)
            return try await search(trackingNumber: trackingNumber, actionID: fresh)
        }
    }

    private func search(trackingNumber: String, actionID: String) async throws -> TrackingInfo {
        var request = URLRequest(url: pageURL)
        request.httpMethod = "POST"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(actionID, forHTTPHeaderField: "Next-Action")
        request.setValue("text/x-component", forHTTPHeaderField: "Accept")

        // React `encodeReply` of `searchPackages(null, formData)`: the FormData's fields are
        // prefixed `_1_` and referenced from the root row `0` as `$K1`.
        let boundary = "TsuiseKit-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = ""
        for (name, value) in [("_1_tracking_number", trackingNumber), ("0", #"[null,"$K1"]"#)] {
            body += "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n"
        }
        body += "--\(boundary)--\r\n"
        request.httpBody = Data(body.utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw TsuiseKitError.networkFailure(statusCode: http.statusCode)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw TsuiseKitError.parseFailure(reason: "Invalid encoding")
        }
        return try parseActionPayload(text, trackingNumber: trackingNumber)
    }

    /// Parses the server action's RSC payload.
    ///
    ///     0:{"a":"$@1",...}
    ///     1:{"ok":true,"results":[{"trackingNumber":...,"status":...,"history":[...]}]}
    private func parseActionPayload(_ payload: String, trackingNumber: String) throws -> TrackingInfo {
        var rows: [String: Substring] = [:]
        for line in payload.split(whereSeparator: \.isNewline) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            rows[String(line[..<colon])] = line[line.index(after: colon)...]
        }

        // Row 0 points at the action's return value ("a":"$@<row>").
        var resultRow = "1"
        if let root = rows["0"],
           let ref = try? JSONDecoder().decode(RootRow.self, from: Data(root.utf8)).a,
           ref.hasPrefix("$@") {
            resultRow = String(ref.dropFirst(2))
        }
        guard let raw = rows[resultRow] else {
            throw TsuiseKitError.parseFailure(reason: "Missing result row")
        }
        let result: SearchResult
        do {
            result = try JSONDecoder().decode(SearchResult.self, from: Data(raw.utf8))
        } catch {
            throw TsuiseKitError.parseFailure(reason: "Unexpected result: \(error)")
        }
        guard result.ok else {
            throw TsuiseKitError.parseFailure(reason: result.message ?? "Search failed")
        }

        let normalized = trackingNumber.replacingOccurrences(of: "-", with: "")
        guard let package = result.results?.first(where: {
            $0.trackingNumber.replacingOccurrences(of: "-", with: "") == normalized
        }) ?? result.results?.first else {
            throw TsuiseKitError.notFound
        }

        let events = package.history.compactMap {
            makeEvent(status: $0.status, date: $0.date, office: $0.office ?? "")
        }

        // "該当なし" (no such parcel) comes back as ok:true with an empty history.
        guard !events.isEmpty else {
            throw TsuiseKitError.notFound
        }

        var currentStatus = package.status.trimmingCharacters(in: .whitespacesAndNewlines)
        if currentStatus.isEmpty {
            currentStatus = events.last?.status ?? ""
        }

        let estimatedDelivery = package.dateLines
            .first { $0.label.contains("配達予定日") }
            .map { $0.value.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }

        return TrackingInfo(
            trackingNumber: trackingNumber,
            carrier: .sagawa,
            itemType: nil,
            currentStatus: currentStatus,
            estimatedDelivery: estimatedDelivery,
            events: events
        )
    }

    /// Finds `createServerReference("<id>", …, "searchPackages")` in the page's JS chunks.
    private static func discoverActionID() async throws -> String {
        var request = URLRequest(url: pageURL)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: request)
        let html = String(decoding: data, as: UTF8.self)

        let chunkPattern = /\/k2k\/_next\/static\/chunks\/[A-Za-z0-9_.~-]+\.js/
        let actionPattern = /createServerReference\)\("([0-9a-f]+)"[^)]*"searchPackages"\)/
        var seen = Set<String>()
        for match in html.matches(of: chunkPattern) {
            let path = String(match.output)
            guard seen.insert(path).inserted,
                  let url = URL(string: path, relativeTo: pageURL) else { continue }
            var chunkRequest = URLRequest(url: url)
            chunkRequest.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            guard let (chunk, _) = try? await URLSession.shared.data(for: chunkRequest) else { continue }
            if let found = String(decoding: chunk, as: UTF8.self).firstMatch(of: actionPattern) {
                return String(found.output.1)
            }
        }
        throw TsuiseKitError.parseFailure(reason: "searchPackages action not found")
    }

    // MARK: - Shared

    /// Both sites prefix history statuses with `↓` / `⇒` arrows.
    private func makeEvent(status: String, date: String, office: String) -> TrackingEvent? {
        let status = status.trimmingCharacters(in: CharacterSet(charactersIn: "↓⇒ \u{3000}").union(.whitespacesAndNewlines))
        let dateRaw = date.trimmingCharacters(in: .whitespacesAndNewlines)
        let office = office.trimmingCharacters(in: .whitespacesAndNewlines)
        if status.isEmpty && dateRaw.isEmpty { return nil }
        return TrackingEvent(
            rawDate: dateRaw,
            date: parseDate(dateRaw),
            status: status,
            location: office.isEmpty ? nil : office
        )
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

/// The last known `searchPackages` action ID, shared across tracker instances.
private actor SagawaActionID {
    static let shared = SagawaActionID()
    private(set) var current = "60e3b76ba7f1d28cf3c3fa01680217528f16cd1984"
    func update(_ id: String) { current = id }
}

private struct RootRow: Decodable {
    let a: String?
}

private struct SearchResult: Decodable {
    let ok: Bool
    let message: String?
    let results: [Package]?

    struct Package: Decodable {
        let trackingNumber: String
        let status: String
        let dateLines: [DateLine]
        let history: [HistoryEntry]
    }

    struct DateLine: Decodable {
        let label: String
        let value: String
    }

    struct HistoryEntry: Decodable {
        let status: String
        let date: String
        let office: String?
    }
}

private let legacyURL = URL(string: "https://k2k.sagawa-exp.co.jp/p/web/okurijosearch.do")!
private let pageURL = URL(string: "https://e-customer.sagawa-exp.co.jp/k2k")!

private let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

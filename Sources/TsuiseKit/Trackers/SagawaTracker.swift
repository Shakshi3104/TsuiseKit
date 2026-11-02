import Foundation

/// Sagawa's tracking page (`e-customer.sagawa-exp.co.jp/k2k`) is a Next.js app.
/// The search form submits a server action (`searchPackages`) that answers with a
/// React Server Components payload whose result row is plain JSON — no HTML scraping.
/// The legacy `k2k.sagawa-exp.co.jp/p/web/okurijosearch.do` endpoint now only serves
/// a Shift_JIS maintenance notice.
public struct SagawaTracker: Tracker {
    public let carrier: Carrier = .sagawa

    public init() {}

    public func fetch(trackingNumber: String) async throws -> TrackingInfo {
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
        return try parse(html: text, trackingNumber: trackingNumber)
    }

    /// Parses the server action's RSC payload (despite the protocol's `html` label).
    ///
    ///     0:{"a":"$@1",...}
    ///     1:{"ok":true,"results":[{"trackingNumber":...,"status":...,"history":[...]}]}
    public func parse(html: String, trackingNumber: String) throws -> TrackingInfo {
        var rows: [String: Substring] = [:]
        for line in html.split(whereSeparator: \.isNewline) {
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

        let events: [TrackingEvent] = package.history.compactMap { entry in
            let status = entry.status.trimmingCharacters(in: CharacterSet(charactersIn: "↓⇒ \u{3000}"))
            let dateRaw = entry.date.trimmingCharacters(in: .whitespacesAndNewlines)
            let office = entry.office?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if status.isEmpty && dateRaw.isEmpty { return nil }
            return TrackingEvent(
                rawDate: dateRaw,
                date: parseDate(dateRaw),
                status: status,
                location: office.isEmpty ? nil : office
            )
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

private let pageURL = URL(string: "https://e-customer.sagawa-exp.co.jp/k2k")!

private let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

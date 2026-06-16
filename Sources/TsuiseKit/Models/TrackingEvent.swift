import Foundation

public struct TrackingEvent: Codable, Sendable, Hashable {
    public let rawDate: String
    public let date: Date?
    public let status: String
    public let location: String?

    public init(rawDate: String, date: Date? = nil, status: String, location: String? = nil) {
        self.rawDate = rawDate
        self.date = date
        self.status = status
        self.location = location
    }
}

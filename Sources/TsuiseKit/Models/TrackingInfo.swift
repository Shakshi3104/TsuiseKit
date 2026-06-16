import Foundation

public struct TrackingInfo: Codable, Sendable, Hashable {
    public let trackingNumber: String
    public let carrier: Carrier
    public let itemType: String?
    public let currentStatus: String
    public let estimatedDelivery: String?
    public let events: [TrackingEvent]

    public init(
        trackingNumber: String,
        carrier: Carrier,
        itemType: String? = nil,
        currentStatus: String,
        estimatedDelivery: String? = nil,
        events: [TrackingEvent]
    ) {
        self.trackingNumber = trackingNumber
        self.carrier = carrier
        self.itemType = itemType
        self.currentStatus = currentStatus
        self.estimatedDelivery = estimatedDelivery
        self.events = events
    }
}

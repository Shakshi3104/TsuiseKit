import Foundation

public protocol Tracker: Sendable {
    var carrier: Carrier { get }
    func fetch(trackingNumber: String) async throws -> TrackingInfo
    func parse(html: String, trackingNumber: String) throws -> TrackingInfo
}

public enum TsuiseKitError: Error, Sendable, Equatable {
    case invalidTrackingNumber
    case networkFailure(statusCode: Int)
    case notFound
    case parseFailure(reason: String)
}

public enum TsuiseKit {
    public static func tracker(for carrier: Carrier) -> any Tracker {
        switch carrier {
        case .japanPost: JapanPostTracker()
        case .yamato:    YamatoTracker()
        case .sagawa:    SagawaTracker()
        }
    }

    public static func fetch(carrier: Carrier, trackingNumber: String) async throws -> TrackingInfo {
        try await tracker(for: carrier).fetch(trackingNumber: trackingNumber)
    }
}

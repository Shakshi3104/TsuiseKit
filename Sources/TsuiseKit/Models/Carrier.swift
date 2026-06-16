import Foundation

public enum Carrier: String, Codable, Sendable, CaseIterable, Hashable {
    case japanPost = "japanpost"
    case yamato = "yamato"
    case sagawa = "sagawa"

    public var displayName: String {
        switch self {
        case .japanPost: "Japan Post"
        case .yamato:    "Yamato Transport"
        case .sagawa:    "Sagawa Express"
        }
    }
}

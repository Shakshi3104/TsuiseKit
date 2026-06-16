import Foundation

public enum Carrier: String, Codable, Sendable, CaseIterable, Hashable {
    case japanPost = "japanpost"
    case yamato = "yamato"
    case sagawa = "sagawa"

    public var displayName: String {
        switch self {
        case .japanPost: "Japan Post"
        case .yamato: "ヤマト運輸"
        case .sagawa: "佐川急便"
        }
    }
}

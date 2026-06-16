# TsuiseKit

A Swift package for tracking parcels shipped via Japanese carriers: **Japan Post (日本郵便)**, **Yamato Transport (クロネコヤマト)**, and **Sagawa Express (佐川急便)**.

No third-party API key is required — `TsuiseKit` scrapes each carrier's public tracking page directly.

## Requirements

- iOS 17+ / macOS 14+
- Swift 6.3+

## Installation

### Swift Package Manager

In Xcode: **File → Add Package Dependencies…** and enter:

```
https://github.com/Shakshi3104/TsuiseKit.git
```

Or in `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/Shakshi3104/TsuiseKit.git", from: "0.1.0"),
],
targets: [
    .target(name: "YourApp", dependencies: ["TsuiseKit"]),
]
```

## Usage

```swift
import TsuiseKit

// 1. Per-carrier tracker
let info = try await JapanPostTracker().fetch(trackingNumber: "3236-8598-1205")
print(info.currentStatus)        // "持ち出し中"
print(info.itemType ?? "-")      // "ゆうパケット"
for event in info.events {
    print(event.rawDate, event.status, event.location ?? "")
}

// 2. Facade — pick a carrier dynamically
let info2 = try await TsuiseKit.fetch(
    carrier: .yamato,
    trackingNumber: "3902-1220-8072"
)
print(info2.estimatedDelivery ?? "-")   // "06/16 08:00-12:00"
```

### Model

```swift
public struct TrackingInfo: Codable, Sendable, Hashable {
    public let trackingNumber: String
    public let carrier: Carrier              // .japanPost / .yamato / .sagawa
    public let itemType: String?             // 商品種別 (Japan Post / Yamato)
    public let currentStatus: String         // most recent status
    public let estimatedDelivery: String?    // delivery window if shown (Yamato / Sagawa)
    public let events: [TrackingEvent]       // chronological — oldest first
}

public struct TrackingEvent: Codable, Sendable, Hashable {
    public let rawDate: String               // e.g. "06/15 12:10"
    public let date: Date?                   // best-effort parsed
    public let status: String                // e.g. "引受", "持ち出し中"
    public let location: String?             // e.g. "新東京郵便局（楽天）"
}
```

## Tested carriers

| Carrier | Method | Returns | Notes |
|---|---|---|---|
| Japan Post | GET | status, history, post-office name | — |
| Yamato | POST | status, history, item type, **estimated delivery time** | Page is JS-assembled; the parser un-escapes `\<`, `\>`, `\/` before parsing |
| Sagawa | POST | status, history, **estimated delivery time** | Status text is read from `<th>`, not `<td>` |

## Tests

```sh
swift test                                    # offline (requires Fixtures/*.html)
RUN_LIVE=1 swift test --filter Live           # hit the real carrier sites
```

Fixtures contain real tracking data from personal shipments and are gitignored. See `Tests/TsuiseKitTests/Fixtures/README.md` for how to regenerate.

## A note on scraping

These carriers do not publish a tracking API for individuals, so `TsuiseKit` parses the same HTML pages your browser would. That means if a carrier overhauls its tracking page, the corresponding parser breaks until it's updated — please open an issue if you spot a regression.

## License

MIT. See `LICENSE`.

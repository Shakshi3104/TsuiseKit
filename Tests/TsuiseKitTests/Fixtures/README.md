# Test Fixtures

This directory holds saved HTML responses from the three carrier tracking pages,
used by `TsuiseKitTests` to verify the parsers offline.

Each fixture is the **raw** response a carrier returned for a real shipment, so
it contains things like delivery branch names and post-office routing data.
For that reason the HTML files themselves are gitignored — to run the offline
suite you need to regenerate them locally.

## How to regenerate

```sh
# Japan Post (GET)
curl -sS 'https://trackings.post.japanpost.jp/services/srv/search/direct?reqCodeNo1=<TRACKING_NUMBER>&searchKind=S004&locale=ja' \
  -H 'User-Agent: Mozilla/5.0' \
  -o japanpost_<TRACKING_NUMBER>.html

# Yamato (POST)
curl -sS -X POST 'https://toi.kuronekoyamato.co.jp/cgi-bin/tneko' \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -H 'User-Agent: Mozilla/5.0' \
  --data-urlencode 'number00=1' \
  --data-urlencode 'number01=<TRACKING_NUMBER>' \
  -o yamato_<TRACKING_NUMBER>.html

# Sagawa (POST)
curl -sS -X POST 'https://k2k.sagawa-exp.co.jp/p/web/okurijosearch.do' \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -H 'User-Agent: Mozilla/5.0' \
  --data-urlencode 'okurijoNo=<TRACKING_NUMBER>' \
  -o sagawa_<TRACKING_NUMBER>.html
```

Update the file names referenced in `TsuiseKitTests.swift` to match. If a
fixture is missing the corresponding test simply skips — only the tests whose
fixtures are present run.

## Offline tests vs live tests

- Offline tests (`@Suite("TsuiseKit parsers")`): require fixtures, run by `swift test`
- Live tests (`@Suite("Live network")`): hit the real carrier sites, run by `RUN_LIVE=1 swift test --filter Live`

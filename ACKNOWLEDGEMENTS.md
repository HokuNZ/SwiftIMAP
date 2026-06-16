# Acknowledgements

SwiftIMAP is released under the MIT License (see [`LICENSE`](LICENSE) — © 2024
Electric Fence Ltd).

With thanks to the open-source packages it builds on, listed below with their
licences. SwiftIMAP is distributed as source
via Swift Package Manager, so each dependency is fetched with its own full
licence (and `NOTICE`, where applicable) — this file is a courtesy
acknowledgement, not a replacement for those. Follow the links for the complete
licence texts.

## Linked into the SwiftIMAP library

- **SwiftNIO** — Apache License 2.0 — https://github.com/apple/swift-nio
- **swift-nio-ssl** — Apache License 2.0 — https://github.com/apple/swift-nio-ssl
- **swift-crypto** — Apache License 2.0 — https://github.com/apple/swift-crypto
- **MimeParser** (HokuNZ fork of `miximka/MimeParser`) — MIT License, © 2017 miximka — https://github.com/HokuNZ/MimeParser

## Command-line tool (`swift-imap-tester`) only

- **swift-argument-parser** — Apache License 2.0 — https://github.com/apple/swift-argument-parser

## Build / documentation tooling only

- **swift-docc-plugin** — Apache License 2.0 — https://github.com/apple/swift-docc-plugin

## Transitive (Apache License 2.0, pulled in by the packages above)

swift-collections, swift-atomics, swift-system, swift-asn1, swift-docc-symbolkit
— © their respective Swift project authors (https://github.com/apple).

---

The Apache 2.0 packages ship `NOTICE` files; those notices apply to each package
as SwiftPM fetches it. If you redistribute a **binary** that statically links
these libraries, include their `NOTICE` contents in your distribution per
Apache 2.0 §4(d). For SwiftIMAP's own source distribution, no aggregated
`NOTICE` is required.

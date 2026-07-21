# Swift Primitive App (Template Package)

This is a Swift Package (SPM) providing the reusable `PrimitiveApp` library. New files are auto-discovered by SPM — no project file changes needed.

> **For a tour of what's in this package and how it's consumed by the apps that depend on it, read [docs/README.md](docs/README.md) first.** It walks through every public type, the auth flow, the `BaoDataLoader` / `LiveText` reactive helpers, and the patterns the demo uses.

## Build

```sh
swift build
```

## Swift Client

The native Swift client lives at `swift-client/` in this repo. It mirrors the JS `js-bao-wss-client` API using native URLSession (HTTP), URLSessionWebSocketTask (WS), and YSwift/Yrs (CRDTs). No JavaScript bridge.

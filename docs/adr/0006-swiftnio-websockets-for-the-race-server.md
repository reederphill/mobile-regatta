# SwiftNIO WebSockets for the race server and the load client

The race server (`RegattaServer`) is built directly on SwiftNIO: `NIOHTTP1` for its few plain routes (`/health`, the dev instant race) and `NIOWebSocket`'s typed upgrader for the race connection at `/race`, with one structured-concurrency task per connection over `NIOAsyncChannel`. The load client (`regatta-loadclient`) uses the same library's WebSocket client upgrader, so the server and its load test share one stack that builds and runs the same on macOS and on the Linux race server. One dependency, `swift-nio`, pinned to a minor version in `Package.swift` and exactly in the committed `Package.resolved`; HMAC for race tokens comes from `swift-crypto`, already in the graph through RegattaCore.

We did this because the server's needs are narrow and the dependency footprint matters on the machine that runs authoritative, replayable races (ADR 0002). The race protocol is our own binary framing over WebSocket binary messages (#18), transport-independent, so the server needs no routing framework, middleware or templating: one upgrade path, two JSON routes, and a socket whose writes the race host can queue without blocking. NIO is the layer every Swift server framework sits on, is maintained by Apple, and supports Swift 6 strict concurrency.

## Considered options

- **Hummingbird 2 (with its WebSocket module):** a light framework on NIO with a router and an async WebSocket API. Rejected for now: it adds several packages (Hummingbird core, its WebSocket and HTTP types, service lifecycle, logging, metrics) for routing we do in a switch statement. Moving the HTTP side onto it later is cheap if the dev and admin routes grow.
- **Vapor:** a full web framework. Far more than a race endpoint needs, and the largest dependency graph.
- **Foundation's `URLSessionWebSocketTask` for the load client:** fine on Apple platforms, but on Linux it needs FoundationNetworking and libcurl, a host dependency the container would have to carry. The app (#68) can still use it: the wire is plain RFC 6455 binary messages, and the client library, RegattaClient, stays transport-free.
- **A raw TCP stream with our own length-prefixed framing:** smallest, but #18 chose WebSocket for v1.0 so the app can use the platform's client and proxies and hosting (Edgegap, GameLift; #4) see an ordinary protocol.

## Consequences

- The race host (`RaceHost`) still knows nothing of sockets: `WebSocketSeatTransport` adapts a NIO channel to its `SeatTransport`, and a client that stops reading is dropped past 256 KB unsent rather than buffered without bound.
- `regatta-loadclient` lives in the RegattaServer package, which now depends on RegattaClient: a client change reaches the server package in `scripts/check.sh`. RegattaClient itself gains no dependency, so the app doesn't link NIO.
- Upgrading `swift-nio` is a deliberate change to `Package.resolved`, reviewed like any other; it changes nothing the simulation computes, so no simulation version bump.
- If the server ever needs HTTP/2, TLS termination in process or a larger admin API, those are NIO modules (`NIOHTTP2`, `NIOSSL`) or a framework on top of the same stack, not a rewrite.

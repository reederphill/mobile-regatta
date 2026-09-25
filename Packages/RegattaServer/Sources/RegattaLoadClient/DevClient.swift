import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import RegattaDevAPI

/// The server's plain HTTP routes, from the client side: a minimal HTTP/1.1 client on NIO, so the load
/// client needs nothing but SwiftNIO on Linux (no FoundationNetworking, no libcurl).
public enum DevClient {
    /// `POST /dev/instant-race`: a race now, and a token per client.
    public static func instantRace(_ request: InstantRaceRequest, host: String, port: Int,
                                   group: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton) async throws -> InstantRaceResponse {
        let (status, body) = try await self.request(.POST, "\(ServerPath.instantRace)?\(request.query)", host: host, port: port, group: group)
        guard status == 201 else { throw LoadClientError.http(status: status, body: String(decoding: body, as: UTF8.self)) }
        return try JSONDecoder().decode(InstantRaceResponse.self, from: Data(body))
    }

    /// `GET /health`.
    public static func health(host: String, port: Int, group: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton) async throws -> HealthStatus {
        let (status, body) = try await request(.GET, ServerPath.health, host: host, port: port, group: group)
        guard status == 200 else { throw LoadClientError.http(status: status, body: String(decoding: body, as: UTF8.self)) }
        return try JSONDecoder().decode(HealthStatus.self, from: Data(body))
    }

    /// One request on its own connection: the status and the body.
    public static func request(_ method: HTTPMethod, _ uri: String, host: String, port: Int,
                               group: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton) async throws -> (status: Int, body: [UInt8]) {
        let channel = try await ClientBootstrap(group: group)
            .connect(host: host, port: port) { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHTTPClientHandlers()
                    return try NIOAsyncChannel<HTTPClientResponsePart, HTTPClientRequestPart>(wrappingChannelSynchronously: channel)
                }
            }
        return try await channel.executeThenClose { inbound, outbound in
            var headers = HTTPHeaders()
            headers.add(name: "Host", value: "\(host):\(port)")
            headers.add(name: "Content-Length", value: "0")
            headers.add(name: "Connection", value: "close")
            try await outbound.write(contentsOf: [
                .head(HTTPRequestHead(version: .http1_1, method: method, uri: uri, headers: headers)),
                .end(nil),
            ])
            var status = 0
            var body: [UInt8] = []
            for try await part in inbound {
                switch part {
                case .head(let head): status = Int(head.status.code)
                case .body(let buffer): body += Array(buffer: buffer)
                case .end: return (status, body)
                }
            }
            throw LoadClientError.http(status: status, body: "connection closed mid-response")
        }
    }
}

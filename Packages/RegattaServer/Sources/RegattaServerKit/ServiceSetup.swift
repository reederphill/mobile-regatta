import Foundation
import GameCenterIdentity
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL
import Persistence
import RegattaDevAPI
import X509

extension ServiceEndpoint {
    /// The endpoint `config` describes, over `store`: the real Game Center verifier when Apple's root is configured,
    /// the dev verifier otherwise (only in `ENV=dev`).
    public static func make(config: ServerConfig, store: any AccountStore, fetcher: (any CertificateFetching)? = nil) throws -> ServiceEndpoint {
        let identity = config.identity
        let verifier: any GameCenterVerifier
        if let pem = identity.appleRootsPEM {
            let pinned = try GameCenterVerifierConfig.certificates(pem: pem)
            verifier = AppleGameCenterVerifier(
                config: GameCenterVerifierConfig(bundleID: identity.bundleID, pinned: pinned, freshness: identity.signatureFreshness),
                fetcher: try fetcher ?? HTTPSCertificateFetcher())
        } else if config.environment.isDev {
            verifier = DevGameCenterVerifier(freshness: identity.signatureFreshness)
        } else {
            throw ServerConfigError.invalid(variable: "REGATTA_APPLE_ROOT_PEM", value: "(unset)", expected: "Apple's root outside ENV=dev")
        }
        return ServiceEndpoint(
            config: ServiceEndpointConfig(termsVersion: identity.termsVersion, sessionLifetime: identity.sessionLifetime,
                                          streamIdleTimeout: identity.streamIdleTimeout, frameCap: identity.frameCap,
                                          serverBuild: config.serverBuild),
            sessions: SessionAuthority(store: store, verifier: verifier, lifetime: identity.sessionLifetime))
    }

    /// `POST /dev/situation` (dev only): puts the test account in the contract situation asked for, and says how
    /// the client signs in for it. Only the suites this server serves: Identity and Terms (#145).
    func arrange(_ request: DevSituationRequest) async -> HTTPReply {
        let current = config.termsVersion
        func signedIn(accepting version: Int?) async -> HTTPReply {
            do {
                _ = try await store.signIn(teamPlayerID: request.teamPlayerID, gamePlayerID: request.gamePlayerID, alias: "Contract")
                if let version { try await store.acceptTerms(playerID: request.teamPlayerID, version: version, at: sessions.now()) }
                return HTTPReply(.ok, json: DevSituationResponse(signIn: true))
            } catch {
                return HTTPReply(.conflict, error: "can't arrange the test account: \(error)")
            }
        }
        switch (request.service, request.situation) {
        case ("IdentityService", "signedOut"): return HTTPReply(.ok, json: DevSituationResponse(signIn: false))
        case ("IdentityService", "signedIn"): return HTTPReply(.ok, json: DevSituationResponse(signIn: true))
        case ("IdentityService", "multiplayerRestricted"):
            return HTTPReply(.ok, json: DevSituationResponse(signIn: true, isMultiplayerGamingRestricted: true))
        case ("TermsService", "neverAccepted"): return await signedIn(accepting: nil)
        case ("TermsService", "accepted"): return await signedIn(accepting: current)
        case ("TermsService", "versionBumped"):
            guard current >= 2 else { return HTTPReply(.conflict, error: "versionBumped needs TERMS_VERSION of 2 or more") }
            return await signedIn(accepting: current - 1)
        default:
            return HTTPReply(.notFound, error: "\(request.service).\(request.situation) isn't served yet")
        }
    }
}

/// Fetches Game Center's certificate over HTTPS (HTTP/1.1 on NIO with NIOSSL: no FoundationNetworking on Linux). The
/// verifier has already checked the URL is Game Center's key host and path; the TLS trust is the system's, loaded
/// once into the context every fetch shares.
public struct HTTPSCertificateFetcher: CertificateFetching {
    /// Game Center's certificate is a couple of KB.
    static let maxBody = 64 * 1024
    let group: any EventLoopGroup
    let timeout: Duration
    let context: NIOSSLContext

    public init(group: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton, timeout: Duration = .seconds(10)) throws {
        self.group = group
        self.timeout = timeout
        context = try NIOSSLContext(configuration: .makeClientConfiguration())
    }

    public enum FetchError: Error, Equatable, Sendable {
        case badURL
        case status(Int)
        case tooLarge
        case incomplete
    }

    /// The request line's target: the path and query as the URL encodes them (never decoded, so a `%0d%0a` stays
    /// three characters each and can't break the request line), and nothing outside printable ASCII.
    static func requestTarget(_ url: URL) throws -> String {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw FetchError.badURL }
        let path = parts.percentEncodedPath.isEmpty ? "/" : parts.percentEncodedPath
        let target = path + (parts.percentEncodedQuery.map { "?" + $0 } ?? "")
        guard target.unicodeScalars.allSatisfy({ $0.value > 0x20 && $0.value < 0x7F }) else { throw FetchError.badURL }
        return target
    }

    public func fetch(_ url: URL) async throws -> [UInt8] {
        guard let host = url.host, url.scheme == "https" else { throw FetchError.badURL }
        let port = url.port ?? 443
        let path = try Self.requestTarget(url)
        let context = context
        let channel = try await ClientBootstrap(group: group)
            .connectTimeout(.seconds(Int64(timeout.components.seconds)))
            .connect(host: host, port: port) { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(NIOSSLClientHandler(context: context, serverHostname: host))
                    try channel.pipeline.syncOperations.addHTTPClientHandlers()
                    return try NIOAsyncChannel<HTTPClientResponsePart, HTTPClientRequestPart>(wrappingChannelSynchronously: channel)
                }
            }
        let deadline = Task {
            try await Task.sleep(for: timeout)
            try await channel.channel.close()
        }
        defer { deadline.cancel() }
        return try await channel.executeThenClose { inbound, outbound in
            var headers = HTTPHeaders()
            headers.add(name: "Host", value: host)
            headers.add(name: "Connection", value: "close")
            try await outbound.write(contentsOf: [
                .head(HTTPRequestHead(version: .http1_1, method: .GET, uri: path, headers: headers)),
                .end(nil),
            ])
            var status = 0
            var body: [UInt8] = []
            for try await part in inbound {
                switch part {
                case .head(let head): status = Int(head.status.code)
                case .body(let buffer):
                    body += Array(buffer: buffer)
                    guard body.count <= Self.maxBody else { throw FetchError.tooLarge }
                case .end:
                    guard status == 200 else { throw FetchError.status(status) }
                    return body
                }
            }
            throw FetchError.incomplete
        }
    }
}

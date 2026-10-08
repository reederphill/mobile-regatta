import Foundation
@testable import RegattaServerKit
import Testing

/// The HTTPS fetcher's request line (#145 review): the path goes out as the URL encodes it, never decoded.
@Suite struct GameCenterFetcherTests {
    @Test func anEncodedCRLFStaysEncodedInTheRequestTarget() throws {
        let url = try #require(URL(string: "https://static.gc.apple.com/public-key/a%0d%0aHost:%20evil.cer"))
        let target = try HTTPSCertificateFetcher.requestTarget(url)
        #expect(target == "/public-key/a%0d%0aHost:%20evil.cer")
        #expect(!target.contains("\r") && !target.contains("\n") && !target.contains(" "))
    }

    @Test func aPlainKeyURLIsItsPath() throws {
        let url = try #require(URL(string: "https://static.gc.apple.com/public-key/gc-prod-10.cer"))
        #expect(try HTTPSCertificateFetcher.requestTarget(url) == "/public-key/gc-prod-10.cer")
        #expect(try HTTPSCertificateFetcher.requestTarget(try #require(URL(string: "https://static.gc.apple.com"))) == "/")
    }
}

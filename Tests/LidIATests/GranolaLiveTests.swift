import Foundation
import Testing
@testable import LidIA

/// Talks to the real https://mcp.granola.ai without signing in. Off by default:
/// run with `LIDIA_LIVE_GRANOLA=1 swift test --filter granolaLive`.
/// Registers one anonymous OAuth client with Granola each run.
private let liveEnabled = ProcessInfo.processInfo.environment["LIDIA_LIVE_GRANOLA"] == "1"

private struct NoTokens: GranolaTokenProviding {
    func accessToken() async throws -> String { "not-a-real-token" }
    func refreshedAccessToken(after failedToken: String) async throws -> String { failedToken }
}

@Test(.enabled(if: liveEnabled)) func granolaLiveDiscoveryRegistrationAnd401() async throws {
    let store = InMemoryGranolaCredentialStore()
    let auth = GranolaAuth(store: store)

    let metadata = await auth.metadata()
    print("LIVE metadata:", metadata)
    #expect(metadata.resource == "https://mcp.granola.ai/mcp")
    #expect(metadata.tokenEndpoint.host == "mcp-auth.granola.ai")
    #expect(metadata.registrationEndpoint != nil)
    #expect(metadata.deviceAuthorizationEndpoint != nil)

    let client = try await auth.registerClient(redirectURI: "http://127.0.0.1:53682/callback")
    print("LIVE registered client:", client.clientID, client.redirectURI ?? "-")
    #expect(client.clientID.hasPrefix("client_"))

    let pkce = PKCEPair.generate()
    let good = try #require(GranolaAuth.authorizationURL(
        metadata: metadata, clientID: client.clientID, redirectURI: "http://127.0.0.1:53682/callback", pkce: pkce, state: "s"
    ))
    let otherPort = try #require(GranolaAuth.authorizationURL(
        metadata: metadata, clientID: client.clientID, redirectURI: "http://127.0.0.1:61001/callback", pkce: pkce, state: "s"
    ))
    let wrongPath = try #require(GranolaAuth.authorizationURL(
        metadata: metadata, clientID: client.clientID, redirectURI: "http://127.0.0.1:53682/other", pkce: pkce, state: "s"
    ))
    let goodOK = await auth.preflight(good)
    let otherPortOK = await auth.preflight(otherPort)
    let wrongPathOK = await auth.preflight(wrongPath)
    print("LIVE preflight registered redirect:", goodOK, "other port:", otherPortOK, "wrong path:", wrongPathOK)
    #expect(goodOK)
    #expect(!wrongPathOK)

    // No sign-in: the MCP endpoint answers 401 and the client reports an expired sign-in.
    let mcp = GranolaMCPClient(tokens: NoTokens())
    do {
        try await mcp.connect()
        Issue.record("connect() should fail without a token")
    } catch let error as GranolaAuthError {
        print("LIVE MCP without token:", error, "-", error.localizedDescription)
        #expect(error == .sessionExpired)
    }

    // And GranolaAuth itself refuses to hand out a token before sign-in.
    await #expect(throws: GranolaAuthError.notSignedIn) { try await auth.accessToken() }
}

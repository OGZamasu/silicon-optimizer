import Foundation

/// The production transport: an ephemeral URLSession with no cookies, no cache and no
/// redirects, that sends only to the ElevenLabs region hosts over https.
public final class URLSessionTransport: ElevenLabsTransport, @unchecked Sendable {
    public init() {}

    public func send(_ request: ElevenLabsRequest) async throws -> ElevenLabsResponse {
        throw ElevenLabsError.network("not implemented yet")
    }

    public func stream(_ request: ElevenLabsRequest) async throws -> ElevenLabsStreamingResponse {
        throw ElevenLabsError.network("not implemented yet")
    }
}

/// A transport that sends nothing: what an app model built for a test or a preview gets, so
/// no code path there can reach ElevenLabs.
public struct UnavailableElevenLabsTransport: ElevenLabsTransport {
    public init() {}

    public func send(_ request: ElevenLabsRequest) async throws -> ElevenLabsResponse {
        throw ElevenLabsError.network("no network in this context")
    }

    public func stream(_ request: ElevenLabsRequest) async throws -> ElevenLabsStreamingResponse {
        throw ElevenLabsError.network("no network in this context")
    }
}

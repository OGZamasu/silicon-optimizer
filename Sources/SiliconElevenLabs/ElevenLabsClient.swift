import Foundation

/// Calls ElevenLabs on the owner's behalf: one instance per linked key and region.
///
/// Every operation in `ElevenLabsCatalog` is reachable through `call`, and the typed helpers
/// in `ElevenLabsClient+Helpers.swift` are thin wrappers over it. The key is read from the
/// credential source at the moment a request is built, sent only in the `xi-api-key` header,
/// and only to the region's host over https.
public actor ElevenLabsClient {
    public nonisolated let region: ElevenLabsRegion
    let credentials: any ElevenLabsCredentialSource
    let transport: any ElevenLabsTransport
    let sink: any ElevenLabsFileSink

    public init(
        credentials: any ElevenLabsCredentialSource, region: ElevenLabsRegion,
        transport: any ElevenLabsTransport, sink: any ElevenLabsFileSink
    ) {
        self.credentials = credentials
        self.region = region
        self.transport = transport
        self.sink = sink
    }

    /// Runs one operation to completion. Big bodies go to the file sink; JSON comes back
    /// inline; SSE and streamed JSON are collected.
    ///
    /// - Parameters:
    ///   - arguments: Path, query and header parameters by name, and the body's fields by
    ///     name (a JSON body may also be given whole as `body`).
    ///   - files: Multipart file fields by name.
    public func call(
        _ operationID: String, arguments: [String: JSONValue] = [:],
        files: [String: [ElevenLabsFile]] = [:]
    ) async throws -> ElevenLabsResult {
        guard let operation = ElevenLabsCatalog.operation(operationID) else {
            throw ElevenLabsError.unknownOperation(operationID)
        }
        return try await call(operation, arguments: arguments, files: files)
    }

    /// `call` for an operation already in hand.
    public func call(
        _ operation: ElevenLabsOperation, arguments: [String: JSONValue] = [:],
        files: [String: [ElevenLabsFile]] = [:]
    ) async throws -> ElevenLabsResult {
        throw ElevenLabsError.network("not implemented yet")
    }

    /// Runs one operation and hands its body over as it arrives: `.started` first, then
    /// audio, events or bytes. Cancelling the consuming task cancels the request.
    public nonisolated func stream(
        _ operationID: String, arguments: [String: JSONValue] = [:],
        files: [String: [ElevenLabsFile]] = [:]
    ) -> AsyncThrowingStream<ElevenLabsChunk, any Error> {
        AsyncThrowingStream { $0.finish(throwing: ElevenLabsError.network("not implemented yet")) }
    }

    /// `GET /v1/user` and `GET /v1/user/subscription`, both free: the plan, the balance and
    /// when it resets. Connect calls this to verify a key before storing it.
    public func account() async throws -> ElevenLabsAccount {
        throw ElevenLabsError.network("not implemented yet")
    }

    /// What `call` would send for these arguments, with the key left out — for "Show API
    /// call". Throws what `call` would throw for invalid arguments.
    public nonisolated func describe(
        _ operationID: String, arguments: [String: JSONValue] = [:],
        files: [String: [ElevenLabsFile]] = [:]
    ) throws -> ElevenLabsCallDescription {
        throw ElevenLabsError.unknownOperation(operationID)
    }

    /// Every problem with these arguments, or none. `call` refuses when this is not empty.
    public nonisolated func validate(
        _ operationID: String, arguments: [String: JSONValue] = [:],
        files: [String: [ElevenLabsFile]] = [:]
    ) -> [String] {
        ElevenLabsCatalog.operation(operationID) == nil
            ? ["There is no ElevenLabs operation named \"\(operationID)\"."] : []
    }
}

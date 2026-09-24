import Foundation
import Testing
@testable import SiliconControl
@testable import SiliconUI

/// The gateway's chat route takes pictures inline, as the control server's chat routes do.
/// It hands messages to the backend as they came, and the llama-server this app bundles —
/// like a node's — downloads an `image_url` that is an address.
@Suite("Chat images through the gateway")
struct GatewayChatImageTests {

    static let address = "http://169.254.169.254/latest/meta-data/"
    static let picture = "data:image/png;base64,iVBORw0KGgo="

    static func chat(image: String, stream: Bool = false) -> String {
        #"{"model":"local/named","stream":\#(stream),"messages":[{"role":"user","content":["#
            + #"{"type":"text","text":"What is this?"},"#
            + #"{"type":"image_url","image_url":{"url":"\#(image)"}}]}]}"#
    }

    @Test func anImageThatIsAnAddressNeverReachesTheBackend() async throws {
        let backend = try CapturingServer { _ in
            #"{"id":"c1","object":"chat.completion","model":"engine-spelling","#
            + #""choices":[{"index":0,"message":{"role":"assistant","content":"a tram"},"#
            + #""finish_reason":"stop"}],"usage":{"prompt_tokens":4,"completion_tokens":2}}"#
        }
        defer { backend.stop() }
        let host = RoutingFakeHost(
            backend: URL(string: "http://127.0.0.1:\(backend.port)/")!, decision: nil
        )
        let (server, port) = try await RoutingGatewayTests.started(host)
        defer { Task { await server.stop() } }

        for body in [
            Self.chat(image: Self.address), Self.chat(image: Self.address, stream: true),
            // The bare-string form some clients send.
            #"{"model":"local/named","messages":[{"role":"user","content":["#
                + #"{"type":"image_url","image_url":"\#(Self.address)"}]}]}"#,
        ] {
            let (status, error) = try await Self.post(body, to: port)
            #expect(status == 400)
            #expect(error == ControlAPI.ChatImages.notInline)
        }
        #expect(backend.requests.isEmpty)
        #expect(await host.log.models.isEmpty, "a model was made ready for it")

        // A picture sent inline goes through as it always did.
        let (status, _) = try await Self.post(Self.chat(image: Self.picture), to: port)
        #expect(status == 200)
        #expect(backend.requests.count == 1)
        #expect(GatewayAPI.carriesOnlyInlineImages(body: Data(#"{"messages":[]}"#.utf8)))
    }

    private static func post(_ body: String, to port: Int) async throws -> (Int, String?) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer gateway-secret", forHTTPHeaderField: "Authorization")
        request.httpBody = Data(body.utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let error = (try? JSONDecoder().decode(ControlAPI.ErrorResponse.self, from: data))?.error
        return (status, error)
    }
}

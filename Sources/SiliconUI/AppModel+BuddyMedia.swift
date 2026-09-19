import AVFoundation
import AppKit
import Foundation
import SiliconControl
import SiliconRuntime

/// What the Mac has to be able to do for a phone to finish a media job: hand back the file
/// it made, make a picture of a clip, and answer "what is that node actually doing?"
///
/// Its own file because all three are things the control target deliberately cannot do for
/// itself — it links nothing but Foundation and Network, so AVFoundation and this Mac's
/// swarm credentials both live up here and arrive through `ControlHost`.
extension AppModel {

    /// The only folders a rendered file may be served from. The same three the gateway's
    /// loopback media serving uses: whatever the owner set as the video, image and 3D
    /// destinations, and nothing wider — a path outside them cannot be registered, so no id
    /// can exist for it and no request can ask for one.
    public func controlMediaRoots() async -> [String] {
        await gatewayMediaRoots()
    }

    /// Pulls a frame out of a clip and writes it as a JPEG.
    ///
    /// Half a second in, not frame zero: a render's first frame is very often black, and a
    /// list of black rectangles is worse than no thumbnails at all. Clips shorter than that
    /// fall back to the start, and anything AVFoundation cannot open answers false — a
    /// missing poster is a clip shown without one, never a failed render.
    public func controlMakeVideoPoster(from source: URL, to destination: URL) async -> Bool {
        let asset = AVURLAsset(url: source)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        // A poster is shown at list size. Asking for the full canvas would decode a 4K
        // frame to throw most of it away.
        generator.maximumSize = CGSize(width: 640, height: 640)
        // Both tolerances zero would make this seek exactly, which on a long GOP means
        // decoding from the last keyframe; a poster does not need that kind of precision.
        generator.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)

        let at = CMTime(seconds: 0.5, preferredTimescale: 600)
        guard let image = try? await generator.image(at: at).image else { return false }
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let jpeg = bitmap.representation(
            using: .jpeg, properties: [.compressionFactor: 0.8]
        ) else { return false }
        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try jpeg.write(to: destination, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// `GET /swarm/peers/{name}/status` — one peer asked now, rather than remembered.
    ///
    /// `GET /swarm` says what the last poll saw, which is the honest shape for a list and
    /// carries two things it cannot: the adapter riding on the node's loaded GGUF, and the
    /// models it has on disk but is not serving. Both come from `/v1/gguf`, which this Mac
    /// has never had a reason to poll.
    ///
    /// The credential is this Mac's per-client token for that peer, or the shared swarm
    /// secret when it holds no better one. It goes out in a header and appears nowhere in
    /// the answer — the whole point of proxying rather than telling the phone the address
    /// and letting it ask.
    public func controlPeerStatus(name: String) async throws -> ControlAPI.PeerNodeStatus {
        guard let config = SwarmConfig.load(),
              let peer = config.peers.first(where: { $0.name == name })
        else { throw ControlAPI.NoSuchPeer(name: name) }
        guard let base = URL(string: peer.baseURL.trimmingCharacters(in: .whitespaces)) else {
            return .init(
                name: peer.name, baseURL: peer.baseURL, reachable: false,
                error: "Not a valid URL."
            )
        }
        return await SwarmPeerProbe.status(
            name: peer.name, base: base, token: config.bearer(forPeer: peer.name)
        )
    }

    /// Which lanes a peer could take work on right now, folded out of its capabilities.
    ///
    /// Kind rather than id, because that is what the rest of the app matches on: a node
    /// advertising `wan22-ti2v-5b` and one advertising the generic `text-to-video` are both
    /// a video lane, and a phone should not have to know the difference to grey out a
    /// button.
    nonisolated static func lanes(of peer: PeerStatus) -> ControlAPI.SwarmView.Lanes {
        func ready(_ kinds: Set<String>) -> Bool {
            peer.capabilities.contains { $0.ready && kinds.contains($0.kind) }
        }
        return ControlAPI.SwarmView.Lanes(
            video: ready(["video", "portrait-animate", "talking-head"]),
            image: ready(["image"]),
            mesh: ready(["mesh", "retopo"]),
            // Serving, not merely installed: a stopped lane cannot answer a chat.
            gguf: peer.llm?.running == true && peer.llm?.healthy == true
        )
    }
}

/// Asks one node the two questions `GET /swarm/peers/{name}/status` forwards.
///
/// Free of `AppModel` so a test can point it at a fake node on loopback and read what comes
/// back, which is the only way to prove a proxy forwards what it should and leaks what it
/// should not.
enum SwarmPeerProbe {

    static func status(
        name: String, base: URL, token: String?
    ) async -> ControlAPI.PeerNodeStatus {
        let policy = RemoteURLPolicy.peerHost(base)
        guard let node = await fetch(
            base.appendingPathComponent("v1/node"), token: token,
            policy: policy, origin: base
        ) else {
            return .init(
                name: name, baseURL: base.absoluteString, reachable: false,
                error: "Unreachable."
            )
        }

        var status = ControlAPI.PeerNodeStatus(
            name: name, baseURL: base.absoluteString, reachable: true
        )
        var parsed = AppModel.PeerStatus(name: name, baseURL: base.absoluteString, reachable: true)
        AppModel.parseNode(node, into: &parsed)
        status.platform = parsed.platform
        status.hardware = parsed.hardware
        status.totalMemoryGB = parsed.totalGB
        status.usedMemoryGB = parsed.usedGB
        status.headroomGB = parsed.headroomGB
        status.gpuUtilization = parsed.gpuUtil
        status.queueDepth = parsed.queueDepth
        status.capabilities = parsed.capabilities.map {
            ControlAPI.SwarmView.Capability(id: $0.id, kind: $0.kind, ready: $0.ready)
        }

        // A node without a llama.cpp lane answers 404 here, which is not an error about the
        // node — it is the answer. The GGUF block is simply absent.
        if let gguf = await fetch(
            base.appendingPathComponent("v1/gguf"), token: token,
            policy: policy, origin: base
        ) {
            status.gguf = parseGGUF(gguf)
        }
        return status
    }

    /// The node's `/v1/gguf`, read leniently: a field it renames degrades to "not
    /// reported", never to a failed request.
    static func parseGGUF(_ json: [String: Any]) -> ControlAPI.PeerNodeStatus.GGUF {
        func text(_ key: String) -> String? {
            guard let value = json[key] as? String, !value.isEmpty else { return nil }
            return value
        }
        func number(_ key: String) -> Double? {
            switch json[key] {
            case let double as Double: double
            case let int as Int: Double(int)
            default: nil
            }
        }
        return .init(
            running: json["running"] as? Bool ?? false,
            model: text("model"),
            // The node calls it `lora`; the app calls it an adapter, because that is what
            // the Models tab calls the same thing on this Mac.
            adapter: text("lora"),
            engine: text("engine_flavor"),
            contextLength: number("context_length").flatMap {
                $0.rounded() == $0 && (1...1_000_000).contains($0) ? Int($0) : nil
            },
            uptimeSeconds: number("uptime_s"),
            installedModels: (json["models"] as? [String]) ?? [],
            adapters: (json["adapters"] as? [String]) ?? []
        )
    }

    private static func fetch(
        _ url: URL, token: String?, policy: RemoteURLPolicy, origin: URL
    ) async -> [String: Any]? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        guard let (data, response) = try? await RemoteHTTP.data(
                for: request, policy: policy, credentialOrigin: origin
              ),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode)
        else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

extension String {
    /// Nil where an empty string would mean "nothing was said". Optional fields on the wire
    /// mean exactly that, and a client that writes `""` for a box the user left alone
    /// should not turn into a request that says something.
    var nilWhenEmpty: String? { isEmpty ? nil : self }
}

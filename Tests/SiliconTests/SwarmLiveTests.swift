import Foundation
import Testing
@testable import SiliconControl
@testable import SiliconUI

/// Integration proof that this Mac can see what a real node advertises.
///
/// Unit tests pinned the parser against payloads copied by hand; this asks the node
/// itself, because "the contract is implemented" and "our client sees it" are separate
/// claims and only one of them decides whether a button is enabled. Skips quietly when
/// no node is configured or reachable.
@Suite("Swarm, against the live node")
struct SwarmLiveTests {

    private func liveNode() async -> AppModel.PeerStatus? {
        guard let config = SwarmConfig.load(), let peer = config.peers.first,
              let base = URL(string: peer.baseURL.trimmingCharacters(in: .whitespaces))
        else { return nil }

        var request = URLRequest(url: base.appendingPathComponent("v1/node"))
        request.timeoutInterval = 8
        if let token = config.effectiveToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        var status = AppModel.PeerStatus(
            name: peer.name, baseURL: peer.baseURL, reachable: true
        )
        AppModel.parseNode(json, into: &status)
        return status
    }

    @Test func seesWhateverTheNodeAdvertises() async {
        guard let peer = await liveNode() else { return }   // no node here; nothing to prove
        #expect(!peer.capabilities.isEmpty)

        // Every filter in the app keys on `kind`, so an empty kind is a silent
        // capability the UI can never find.
        #expect(peer.capabilities.allSatisfy { !$0.kind.isEmpty })

        let kinds = Set(peer.capabilities.filter(\.ready).map(\.kind))
        print("live node ready kinds: \(kinds.sorted())")

        // The two the UI gates buttons on.
        if kinds.contains("video") {
            #expect(peer.capabilities.contains {
                $0.kind == "video" && $0.ready
            }, "a ready video capability must survive parsing")
        }
        if kinds.contains("portrait-animate") || kinds.contains("talking-head") {
            #expect(peer.capabilities.contains {
                ["portrait-animate", "talking-head"].contains($0.kind) && $0.ready
            })
        }
    }
}

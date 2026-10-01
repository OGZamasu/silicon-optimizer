import Foundation
import SiliconElevenLabs

/// The app's one production socket opener (one URLSession for every realtime session).
enum ElevenLabsLiveSockets {
    static let production = URLSessionWebSocketConnector()
}

extension AppModel {
    /// Where realtime sessions open their sockets: the production connector only when the link's
    /// REST transport is the production one. An app model built with injected settings (tests,
    /// previews) has an inert transport, and so opens no socket either.
    var elevenLabsSocketConnector: any ElevenLabsSocketConnector {
        elevenLabsLink.transport is URLSessionTransport
            ? ElevenLabsLiveSockets.production : UnavailableElevenLabsSocketConnector()
    }
}

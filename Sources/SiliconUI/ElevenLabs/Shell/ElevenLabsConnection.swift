import Foundation
import Observation
import SiliconElevenLabs

/// What Settings → ElevenLabs does, apart from drawing it: connect a key (verified first,
/// stored only if it works), remove it, and change region without leaving a key pointed at a
/// workspace it does not belong to.
@MainActor
@Observable
final class ElevenLabsConnectionModel {

    /// A region change waiting for the owner's answer, asked only while a key is linked.
    struct RegionChange: Identifiable, Equatable {
        let id = UUID()
        var from: ElevenLabsRegion
        var to: ElevenLabsRegion
        /// Global and US-only are one account with one key; each residency region is a
        /// workspace of its own whose keys work nowhere else.
        var keyCarriesOver: Bool
    }

    private(set) var verifying = false
    /// Why the last Connect failed, never containing the key.
    private(set) var failure: String?
    /// Set by a Connect that worked, for a line of thanks until the next action.
    private(set) var connected = false
    private(set) var pendingRegionChange: RegionChange?

    init() {}

    /// Verifies `key` against the chosen region's free account call and stores it only if
    /// that works. True when it did; the caller clears its draft then, and keeps it
    /// otherwise, so a typo can be fixed rather than retyped.
    @discardableResult
    func connect(key: String, model: AppModel) async -> Bool {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !verifying else { return false }
        verifying = true
        failure = nil
        connected = false
        defer { verifying = false }
        do {
            _ = try await model.linkElevenLabs(key: key)
            model.elevenLabsPane.reset()
            connected = true
            return true
        } catch {
            failure = Self.describe(error, key: key, region: model.elevenLabsRegion)
            return false
        }
    }

    /// Removes the key; the pane leaves the sidebar.
    func remove(model: AppModel) {
        failure = nil
        connected = false
        pendingRegionChange = nil
        model.disconnectElevenLabs()
    }

    /// The region picker's setter. Unlinked, the region just changes. Linked, it asks first:
    /// the stored key may not work on the new host.
    func requestRegion(_ region: ElevenLabsRegion, model: AppModel) {
        let current = model.elevenLabsRegion
        guard region != current else { return }
        guard model.elevenLabsLinked else {
            model.elevenLabsRegion = region
            failure = nil
            return
        }
        pendingRegionChange = RegionChange(
            from: current, to: region, keyCarriesOver: !current.isResidency && !region.isResidency
        )
    }

    /// Switches with the same key — offered only between the regions that share one — and
    /// checks the account again on the new host.
    func switchRegionKeepingKey(model: AppModel) async {
        guard let change = pendingRegionChange, change.keyCarriesOver else { return }
        pendingRegionChange = nil
        model.elevenLabsRegion = change.to
        model.elevenLabsLink.account = nil
        model.elevenLabsPane.reset()
        await model.refreshElevenLabsBalance()
    }

    /// Removes the key and switches, so the new region's own key can be entered.
    func removeKeyAndSwitchRegion(model: AppModel) {
        guard let change = pendingRegionChange else { return }
        pendingRegionChange = nil
        remove(model: model)
        model.elevenLabsRegion = change.to
    }

    func cancelRegionChange() {
        pendingRegionChange = nil
    }

    /// A failed Connect in words, the key taken out of anything that might echo it.
    static func describe(_ error: any Error, key: String, region: ElevenLabsRegion) -> String {
        let failure = ElevenLabsRunnerFailure(error)
        let message: String
        switch failure {
        case .keyRejected(let answer), .forbidden(let answer):
            message = "\(region.displayName) did not accept this key, so nothing was saved. "
                + "A key works only in the region it was made for. (\(answer))"
        case .offline(let why):
            message = why + " Nothing was saved; a key already connected is still connected."
        default:
            message = failure.message
        }
        return ElevenLabsRedaction.redact(message, knownKey: key)
    }
}

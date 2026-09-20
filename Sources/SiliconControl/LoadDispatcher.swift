import Foundation

/// Runs `POST /load` so that the load outlives the request that asked for it.
///
/// The bug this exists for: the route ran the load inside the request's own task and awaited
/// it to the end — up to the runtime's full ten-minute timeout. Two things follow from that,
/// and both are wrong. Anything that cancels the request's task cancels the load with it,
/// because the runtime watches `Task.isCancelled` while it waits for the server to answer —
/// so a load this Mac was *told* to do could end because a phone locked its screen, and the
/// failure that followed was indistinguishable from a model that could not load. And a
/// connection was held for the whole load, out of a fixed budget of them, on behalf of a
/// caller who may have stopped listening minutes earlier.
///
/// So the load runs detached, and the request only *watches* it. If it finishes inside
/// `patience` the caller gets exactly what it always got. If it does not, the caller gets the
/// live status — the same shape, the same `state` line as `GET /status` — and the load carries
/// on. Nothing about that is new to a client: "still loading" is a state it already renders.
///
/// The owner asked this machine to do something. A dropped socket is not a change of mind.
actor LoadDispatcher {

    /// What the route should say.
    enum Answer: Sendable {
        /// The load finished within the request, and this is its result.
        case finished(ControlAPI.Status)
        /// It is still going. Answer with the live status; the load is not affected.
        case stillLoading
    }

    private struct Running {
        var id: UUID
        var modelID: String
        var startedAt: Date
    }

    private var running: Running?
    /// The result of the most recent load, kept only long enough for the request that asked
    /// for it to pick it up. One slot, so nothing accumulates when nobody is listening.
    private var settled: (id: UUID, result: Result<ControlAPI.Status, any Error>)?

    /// Whether a load is in flight right now.
    var isLoading: Bool { running != nil }

    func load(
        _ request: ControlAPI.LoadRequest,
        on host: any ControlHost,
        patience: Duration = ControlServer.defaultLoadPatience
    ) async throws -> Answer {
        if let running {
            throw ControlAPI.LoadAlreadyRunning(
                modelID: running.modelID,
                secondsAgo: max(0, Int(Date().timeIntervalSince(running.startedAt).rounded()))
            )
        }

        let id = UUID()
        running = Running(id: id, modelID: request.modelID, startedAt: Date())

        // Detached on purpose: an unstructured child of this request would be cancelled with
        // it, which is the bug. The load belongs to the Mac now, not to the socket.
        Task.detached { [self] in
            do {
                await finish(id, .success(try await host.load(request)))
            } catch {
                await finish(id, .failure(error))
            }
        }

        // Polled rather than awaited, and that is deliberate: awaiting the detached task
        // would mean either cancelling it when this wait ends — the thing we are fixing — or
        // holding this request open until it finishes, which is the other thing we are
        // fixing. 25 ms of latency on a load reply is not a cost anyone can perceive.
        let deadline = ContinuousClock.now + patience
        while ContinuousClock.now < deadline {
            if let result = take(id) {
                return .finished(try result.get())
            }
            // The caller has hung up. The load carries on; there is just nobody to tell.
            if Task.isCancelled { return .stillLoading }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return .stillLoading
    }

    private func finish(_ id: UUID, _ result: Result<ControlAPI.Status, any Error>) {
        guard running?.id == id else { return }
        running = nil
        settled = (id, result)
    }

    private func take(_ id: UUID) -> Result<ControlAPI.Status, any Error>? {
        guard let settled, settled.id == id else { return nil }
        self.settled = nil
        return settled.result
    }
}

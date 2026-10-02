import SwiftUI

/// Brings the account's Flows video models into the main Video tab. It deliberately shares
/// the Flows section model so both places use the same generated schemas, credit safeguards,
/// request runner, generation history and unknown-outcome handling.
struct ElevenLabsVideoTabCard: View {
    @Environment(AppModel.self) private var app
    @State private var isExpanded = true

    private var flows: FlowsSectionModel {
        VoicesStudioModels.model(FlowsSectionModel.self, for: app) {
            environment in FlowsSectionModel(environment: environment)
        }
    }

    var body: some View {
        let flows = flows
        CollapsibleCard(
            title: "ElevenLabs video", systemImage: "film.stack",
            badge: app.elevenLabsLinked ? "connected" : "connect key",
            isExpanded: $isExpanded
        ) {
            VStack(alignment: .leading, spacing: 12) {
                if app.elevenLabsLinked {
                    Text("Hosted video generation through ElevenLabs. Choose a model to see its supported settings. Generations use credits.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("If a model is rejected, check that your API key has Image & Video generation access in ElevenLabs.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if flows.model(.video).hasPrefix("bytedance-seedance-") {
                        Label("ElevenLabs requires approval before ByteDance Seedance models can run.",
                              systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    FlowsCreateCard(model: flows, kind: .video).fields
                    Divider()
                    FlowsGenerationsCard(model: flows, kind: .video).content
                    VoicesStudioActivity(
                        actions: flows.actions,
                        fallback: flows.actions.runner("list_video_generations"),
                        showsResult: false
                    )
                } else {
                    Label("Connect an ElevenLabs API key in Settings → ElevenLabs to use hosted video models.",
                          systemImage: "key")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .task(id: app.elevenLabsLinked) {
            guard app.elevenLabsLinked, !flows.loaded.contains(.video) else { return }
            await flows.refresh(.video)
        }
    }
}

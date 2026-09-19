import Foundation
import SiliconControl
import SiliconCore
import SiliconRuntime
import SwiftUI

/// Settings → Silicon Buddy → Models for your phone.
///
/// A paired phone asks for these itself, over `/ondevice/models`. This row is the owner's
/// view of the same thing — which ones the Mac has fetched for the phone, and the way to
/// fetch one ahead of time or take the Mac's copy back. Nothing here loads a model on the
/// Mac; these files are only ever passed along to the phone.
struct BuddyPhoneModelsRow: View {
    private let service = PhoneModelService.shared
    @State private var models: [ControlAPI.PhoneModel] = []
    @State private var problem: String?
    @State private var busy: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Models for your phone")
                .font(.subheadline.weight(.medium))
            Text(
                "When this Mac is out of reach, a paired phone can answer by itself with one of "
                    + "these. The Mac downloads the file from Hugging Face, checks it, and hands it "
                    + "to the phone over your tailnet. Kept in "
                    + "\((service.folder.path as NSString).abbreviatingWithTildeInPath)."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            ForEach(models, id: \.id) { model in
                row(model)
            }
            if let problem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // Read while the section is on screen, and not otherwise: the list is two stats and
        // two small reads per model, and a download's progress moves once a second.
        .task {
            while !Task.isCancelled {
                models = await service.phoneModels().models
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    @ViewBuilder
    private func row(_ model: ControlAPI.PhoneModel) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.isDefault ? "\(model.label) (default)" : model.label)
                Text(Self.describe(model))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            switch model.onMac.state {
            case "ready":
                Button("Remove") { remove(model) }
                    .buttonStyle(.link)
            case "downloading":
                Button("Cancel") { remove(model) }
                    .buttonStyle(.link)
            default:
                Button("Download") { prepare(model) }
                // A failure that left a partial on disk can be resumed or thrown away.
                if model.onMac.fraction != nil {
                    Button("Remove") { remove(model) }
                        .buttonStyle(.link)
                }
            }
        }
        .disabled(busy.contains(model.id))
    }

    /// "1.3 GB · Apache-2.0 · downloading 42%" — what the row says under the name.
    static func describe(_ model: ControlAPI.PhoneModel) -> String {
        var parts = [Bytes(model.sizeBytes).formatted, model.licence]
        switch model.onMac.state {
        case "ready":
            parts.append("on this Mac, verified")
        case "downloading":
            parts.append("downloading \(Int(((model.onMac.fraction ?? 0) * 100).rounded(.down)))%")
        case "failed":
            parts.append(model.onMac.reason ?? "failed")
        default:
            parts.append("not on this Mac")
        }
        if model.slowerOnPhone { parts.append("slower on the phone") }
        return parts.joined(separator: " · ")
    }

    private func prepare(_ model: ControlAPI.PhoneModel) {
        busy.insert(model.id)
        Task {
            do {
                _ = try await service.preparePhoneModel(id: model.id)
                problem = nil
            } catch {
                problem = error.localizedDescription
            }
            models = await service.phoneModels().models
            busy.remove(model.id)
        }
    }

    private func remove(_ model: ControlAPI.PhoneModel) {
        busy.insert(model.id)
        Task {
            do {
                _ = try await service.removePhoneModel(id: model.id)
                problem = nil
            } catch {
                problem = error.localizedDescription
            }
            models = await service.phoneModels().models
            busy.remove(model.id)
        }
    }
}

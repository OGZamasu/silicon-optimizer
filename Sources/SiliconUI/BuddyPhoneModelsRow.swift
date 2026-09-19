import Foundation
import SiliconCatalog
import SiliconControl
import SiliconCore
import SiliconRuntime
import SwiftUI

/// Settings → Silicon Buddy → Models for your phone.
///
/// A paired phone asks for these itself, over `/ondevice/models`. This row is the owner's
/// view of the same thing — which ones the Mac has fetched for the phone, where they are,
/// and the way to fetch one ahead of time, stop a download, or take the Mac's copy back.
/// Nothing here loads a model on the Mac; these files are only ever passed along.
struct BuddyPhoneModelsRow: View {
    @Environment(AppModel.self) private var model
    @State private var models: [ControlAPI.PhoneModel] = []
    @State private var place: PhoneModelPlace?
    @State private var notices: [PhoneModelStore.Notice] = []
    @State private var problem: String?
    @State private var busy: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Models for your phone")
                .font(.subheadline.weight(.medium))
            Text(Self.explain(place))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(models, id: \.id) { model in
                row(model)
            }
            ForEach(notices, id: \.folder) { notice in
                Text("\((notice.folder.path as NSString).abbreviatingWithTildeInPath): \(notice.reason)")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let problem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // Read while the section is on screen, and not otherwise: the list is a few stats
        // and small reads per model, and a download's progress moves once a second. It is
        // also what notices a model library moved in Settings, and moves these with it.
        .task {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func refresh() async {
        let phoneModels = model.phoneModels
        models = await phoneModels.phoneModels().models
        place = await phoneModels.place()
        notices = await phoneModels.notices()
    }

    /// The paragraph under the heading: what these are, and where they are kept.
    static func explain(_ place: PhoneModelPlace?) -> String {
        let what = "When this Mac is out of reach, a paired phone can answer by itself with one "
            + "of these. The Mac downloads the file from Hugging Face, checks it, and hands it "
            + "to the phone over your tailnet."
        switch place {
        case .folder(let folder):
            return what + " Kept in \((folder.path as NSString).abbreviatingWithTildeInPath)."
        case .driveMissing(let drive):
            return what + " They are kept beside the model library, on “\(drive)”, which is "
                + "not connected."
        case nil:
            return what
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
                // Stop keeps what arrived, so Download resumes it; Remove throws it away.
                Button("Stop") { stop(model) }
                    .buttonStyle(.link)
                Button("Remove") { remove(model) }
                    .buttonStyle(.link)
            default:
                if model.onMac.failure != "driveMissing" {
                    Button(model.onMac.fraction == nil ? "Download" : "Resume") { prepare(model) }
                }
                if model.onMac.fraction != nil, model.onMac.failure != "driveMissing" {
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
        let percent = Int(((model.onMac.fraction ?? 0) * 100).rounded(.down))
        switch model.onMac.state {
        case "ready":
            parts.append("on this Mac, verified")
        case "downloading":
            switch model.onMac.stage {
            case "checking": parts.append("Checking… \(percent)%")
            case "moving": parts.append("Moving with the model library…")
            default: parts.append("downloading \(percent)%")
            }
        case "failed":
            parts.append(model.onMac.reason ?? "failed")
        default:
            parts.append("not on this Mac")
        }
        if model.slowerOnPhone { parts.append("slower on the phone") }
        return parts.joined(separator: " · ")
    }

    private func prepare(_ phoneModel: ControlAPI.PhoneModel) {
        act(on: phoneModel) { models in
            _ = try await models.preparePhoneModel(id: phoneModel.id, verify: false)
        }
    }

    private func stop(_ phoneModel: ControlAPI.PhoneModel) {
        act(on: phoneModel) { models in _ = await models.cancel(id: phoneModel.id) }
    }

    private func remove(_ phoneModel: ControlAPI.PhoneModel) {
        act(on: phoneModel) { models in _ = try await models.removePhoneModel(id: phoneModel.id) }
    }

    private func act(
        on phoneModel: ControlAPI.PhoneModel,
        _ work: @escaping @MainActor (PhoneModelsAtLibrary) async throws -> Void
    ) {
        busy.insert(phoneModel.id)
        let phoneModels = model.phoneModels
        Task {
            do {
                try await work(phoneModels)
                problem = nil
            } catch {
                problem = error.localizedDescription
            }
            await refresh()
            busy.remove(phoneModel.id)
        }
    }
}

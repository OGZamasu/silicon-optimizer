import SiliconElevenLabs
import SwiftUI

/// The Explorer: every operation in the catalog, searchable and filterable, each with a form
/// generated from its schema, a Run button and the result.
struct ElevenLabsExplorer: View {
    var body: some View {
        ElevenLabsSectionPage(.explorer) {
            Text("\(ElevenLabsCatalog.all.count) operations.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

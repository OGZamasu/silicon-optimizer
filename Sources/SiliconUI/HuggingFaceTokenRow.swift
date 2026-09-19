import SwiftUI

/// Credential edits stay local until the user commits them. The parent form can autosave
/// ordinary preferences without submitting each keystroke to Keychain.
struct HuggingFaceTokenRow: View {
    @Environment(AppModel.self) private var model
    @State private var draft = ""
    @State private var status = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SecureField("Access token", text: $draft)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("Save token") {
                    if model.settings.saveHuggingFaceToken(draft) {
                        draft = model.settings.huggingFaceToken
                        status = "Token saved."
                    } else {
                        status = "The token could not be saved. Your previous token was kept."
                    }
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Remove token") {
                    if model.settings.saveHuggingFaceToken("") {
                        draft = ""
                        status = "Token removed."
                    } else {
                        status = "The token could not be removed. Your previous token was kept."
                    }
                }
                .disabled(model.settings.huggingFaceToken.isEmpty
                          && !model.settings.huggingFaceTokenNeedsAuthorization)
            }
            if model.settings.huggingFaceTokenNeedsAuthorization {
                Text("Access to your saved token needs approval. Local chat is still available.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Authorize saved token") {
                    if model.settings.authorizeHuggingFaceToken() {
                        draft = model.settings.huggingFaceToken
                        status = draft.isEmpty ? "No saved token was found." : "Saved token is ready."
                    } else {
                        status = "Access was not granted. Your saved token was kept."
                    }
                }
            }
            if !status.isEmpty {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear { draft = model.settings.huggingFaceToken }
    }
}

import SwiftUI

struct SpeakerRenameView: View {
    let currentName: String
    let fallbackName: String
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename speaker").font(.title2.weight(.semibold))
            TextField(fallbackName, text: $name)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Speaker name")
            Text("An empty name uses “\(fallbackName)”.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { onSave(name); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 360)
        .onAppear { name = currentName }
    }
}

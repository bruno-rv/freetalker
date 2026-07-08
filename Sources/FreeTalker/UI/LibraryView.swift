import AppKit
import SwiftUI

struct LibraryView: View {
    @ObservedObject private var store = LibraryStore.shared
    @State private var selectedID: Int64?

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                TextField("Search", text: $store.searchText)
                    .textFieldStyle(.roundedBorder)
                    .padding(8)
                List(store.dictations, selection: $selectedID) { dictation in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(dictation.refined.isEmpty ? dictation.transcript : dictation.refined)
                            .lineLimit(2)
                            .font(.callout)
                        HStack(spacing: 6) {
                            Text(dictation.templateName)
                            Text("·")
                            Text(dictation.language)
                            Text("·")
                            Text(dictation.timestamp, style: .date)
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                    .tag(dictation.id)
                }
            }
            .frame(minWidth: 260)

            if let selectedID, let dictation = store.dictations.first(where: { $0.id == selectedID }) {
                DictationDetailView(dictation: dictation)
            } else {
                Text("Select a Dictation").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 720, height: 480)
    }
}

private struct DictationDetailView: View {
    let dictation: Dictation
    @State private var reprocessing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                labeledText("Transcript", dictation.transcript)
                labeledText("Refined Output", dictation.refined)

                HStack {
                    Text("Template: \(dictation.templateName)")
                    Spacer()
                    Text("Engine: \(dictation.engine)")
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                Menu(reprocessing ? "Re-processing…" : "Re-process with…") {
                    ForEach(TemplateStore.shared.templates) { template in
                        Button(template.name) {
                            reprocessing = true
                            Task {
                                await AppCoordinator.shared.reprocess(dictation: dictation, with: template)
                                reprocessing = false
                            }
                        }
                    }
                }
                .disabled(reprocessing)
            }
            .padding()
        }
    }

    private func labeledText(_ label: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.headline)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.plain)
            }
            Text(text)
                .textSelection(.enabled)
                .font(.body)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}

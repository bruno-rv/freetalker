import AppKit
import SwiftUI

enum SettingsDestination: String, CaseIterable, Identifiable {
    case privacy
    case recording
    case transcription
    case processing
    case launcher
    case storage
    case templates
    case snippets

    var id: Self { self }

    var title: String {
        switch self {
        case .privacy: "Privacy"
        case .recording: "Recording"
        case .transcription: "Transcription"
        case .processing: "Processing"
        case .launcher: "Launcher"
        case .storage: "Storage"
        case .templates: "Templates"
        case .snippets: "Snippets"
        }
    }

    /// Generated sidebar artwork is decorative; the destination title remains its accessible name.
    var imageName: String { rawValue }
}

struct SettingsSidebar: View {
    @Binding var selection: SettingsDestination

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("FreeTalker")
                .font(.headline)
                .padding(.horizontal, 8)
                .padding(.bottom, 8)

            ForEach(SettingsDestination.allCases) { destination in
                Button {
                    selection = destination
                } label: {
                    HStack(spacing: 8) {
                        Image(destination.imageName, bundle: SettingsIconResources.bundle)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                            .frame(width: 20, height: 20)
                            .accessibilityHidden(true)
                        Text(destination.title)
                    }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 7)
                        .contentShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(destination.title)
                .foregroundStyle(selection == destination ? .primary : .secondary)
                .background(
                    selection == destination ? Color.accentColor.opacity(0.18) : .clear,
                    in: RoundedRectangle(cornerRadius: 6)
                )
                .accessibilityValue(selection == destination ? "Selected" : "")
            }

            Spacer()
        }
        .padding(12)
        .frame(minWidth: 180, idealWidth: 196, maxWidth: 220, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private enum SettingsIconResources {
    static let bundle: Bundle = {
        guard let resourceURL = Bundle.main.resourceURL else { return .module }
        let packagedBundle = resourceURL.appendingPathComponent("FreeTalker_FreeTalker.bundle")
        return Bundle(path: packagedBundle.path) ?? .module
    }()
}

struct SettingsPage<Content: View>: View {
    let title: String
    let subtitle: String?
    private let content: Content

    init(
        title: String,
        subtitle: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.title2.weight(.semibold))
                    if let subtitle {
                        Text(subtitle)
                            .foregroundStyle(.secondary)
                    }
                }

                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct SettingsEditorPage<Content: View>: View {
    let title: String
    let subtitle: String?
    private let content: Content

    init(
        title: String,
        subtitle: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title2.weight(.semibold))
                if let subtitle {
                    Text(subtitle)
                        .foregroundStyle(.secondary)
                }
            }

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(24)
    }
}

struct SettingsCard<Content: View>: View {
    let title: String
    let subtitle: String?
    private let content: Content

    init(
        title: String,
        subtitle: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)

            Divider()

            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(nsColor: .separatorColor).opacity(0.45))
        }
    }
}

struct SettingsHelpButton: View {
    let title: String
    let message: String
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: "questionmark.circle")
        }
        .buttonStyle(.plain)
        .help(message)
        .accessibilityLabel("Help: \(title)")
        .popover(isPresented: $isPresented, arrowEdge: .trailing) {
            Text(message)
                .padding()
                .frame(maxWidth: 280, alignment: .leading)
        }
    }
}

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
    case library
    case stats

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
        case .library: "Library"
        case .stats: "Usage Statistics"
        }
    }

    /// Generated sidebar artwork is decorative; the destination title remains its accessible name.
    var imageName: String { rawValue }
}

/// Lets any part of the app open the Settings window
/// pre-selected to a specific tab. `SettingsView` seeds its initial `selection` from
/// `pendingDestination` and also observes it for changes while already open, so setting this
/// then opening/activating the "settings" window scene navigates there either way.
@MainActor
final class SettingsNavigator: ObservableObject {
    static let shared = SettingsNavigator()
    @Published var pendingDestination: SettingsDestination?
    private init() {}
}

enum SettingsSidebarMetrics {
    static let rowSpacing: CGFloat = 10
    static let iconSize: CGFloat = 28
    static let textSize: CGFloat = 14
    static let horizontalPadding: CGFloat = 10
    static let verticalPadding: CGFloat = 7
    static let cornerRadius: CGFloat = 8
    static let headerSize: CGFloat = 15
    static let minimumWidth: CGFloat = 200
    static let idealWidth: CGFloat = 216
    static let maximumWidth: CGFloat = 240
}

struct SettingsSidebar: View {
    @Binding var selection: SettingsDestination

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("FreeTalker")
                .font(.system(size: SettingsSidebarMetrics.headerSize, weight: .semibold))
                .padding(.horizontal, 8)
                .padding(.bottom, 8)

            ForEach(SettingsDestination.allCases) { destination in
                Button {
                    selection = destination
                } label: {
                    HStack(spacing: SettingsSidebarMetrics.rowSpacing) {
                        if let icon = SettingsIconResources.image(named: destination.imageName) {
                            Image(nsImage: icon)
                                .resizable()
                                .interpolation(.high)
                                .scaledToFit()
                                .frame(
                                    width: SettingsSidebarMetrics.iconSize,
                                    height: SettingsSidebarMetrics.iconSize
                                )
                                .accessibilityHidden(true)
                        }
                        Text(destination.title)
                            .font(.system(size: SettingsSidebarMetrics.textSize, weight: .medium))
                            .lineLimit(1)
                    }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, SettingsSidebarMetrics.horizontalPadding)
                        .padding(.vertical, SettingsSidebarMetrics.verticalPadding)
                        .contentShape(RoundedRectangle(
                            cornerRadius: SettingsSidebarMetrics.cornerRadius
                        ))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(destination.title)
                .foregroundStyle(selection == destination ? .primary : .secondary)
                .background(
                    selection == destination ? Color.accentColor.opacity(0.18) : .clear,
                    in: RoundedRectangle(cornerRadius: SettingsSidebarMetrics.cornerRadius)
                )
                .accessibilityValue(selection == destination ? "Selected" : "")
            }

            Spacer()
        }
        .padding(12)
        .frame(
            minWidth: SettingsSidebarMetrics.minimumWidth,
            idealWidth: SettingsSidebarMetrics.idealWidth,
            maxWidth: SettingsSidebarMetrics.maximumWidth,
            maxHeight: .infinity,
            alignment: .topLeading
        )
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

enum SettingsIconResources {
    static let bundle: Bundle = {
        guard let resourceURL = Bundle.main.resourceURL else { return .module }
        let packagedBundle = resourceURL.appendingPathComponent("FreeTalker_FreeTalker.bundle")
        return Bundle(path: packagedBundle.path) ?? .module
    }()

    static func image(
        named name: String,
        in bundle: Bundle = SettingsIconResources.bundle
    ) -> NSImage? {
        guard let url = bundle.url(forResource: name, withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }
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
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

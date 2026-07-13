import AppKit
import SwiftUI

enum SettingsDestination: String, CaseIterable, Identifiable {
    case general
    case templates
    case snippets

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .templates: "Templates"
        case .snippets: "Snippets"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .templates: "text.badge.checkmark"
        case .snippets: "text.quote"
        }
    }
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
                    Label(destination.title, systemImage: destination.systemImage)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 7)
                        .contentShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
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

struct SettingsRow<Trailing: View>: View {
    let title: String
    let detail: String?
    let helpTitle: String?
    let helpMessage: String?
    private let trailing: Trailing

    init(
        _ title: String,
        detail: String? = nil,
        helpTitle: String? = nil,
        helpMessage: String? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.detail = detail
        self.helpTitle = helpTitle
        self.helpMessage = helpMessage
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(title)
                    if let helpTitle, let helpMessage {
                        SettingsHelpButton(title: helpTitle, message: helpMessage)
                    }
                }
                if let detail {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 16)
            trailing
        }
        .padding(.vertical, 8)
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

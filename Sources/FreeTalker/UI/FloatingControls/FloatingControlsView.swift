import SwiftUI

struct FloatingControlsView: View {
    let state: FloatingControlsHoverState
    let edge: LauncherEdge
    let languagePin: String
    let translationState: TranslationControlsState
    let callbacks: FloatingControlsController.Callbacks

    var body: some View {
        Group {
            if state == .collapsed {
                Capsule()
                    .fill(Color.accentColor.gradient)
                    .frame(width: edge.isVertical ? 8 : 48, height: edge.isVertical ? 48 : 8)
                    .accessibilityLabel("Open FreeTalker controls")
            } else {
                controlStack
                    .padding(6)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 13))
                    .overlay(RoundedRectangle(cornerRadius: 13).stroke(.tint.opacity(0.45)))
            }
        }
        .padding(3)
    }

    @ViewBuilder private var controlStack: some View {
        if edge.isVertical {
            VStack(spacing: 4) { controls }
        } else {
            HStack(spacing: 4) { controls }
        }
    }

    @ViewBuilder private var controls: some View {
        launcherButton("Start dictation", systemImage: "mic.fill", action: callbacks.onDictation)
        launcherButton("Open Scratchpad", systemImage: "square.and.pencil", action: callbacks.onScratchpad)
        launcherButton("Open FreeTalker", systemImage: "gearshape.fill", action: callbacks.onOpenSettings)
        TranslationControls(
            languagePin: languagePin,
            state: translationState,
            onLanguage: callbacks.onLanguage,
            onOutput: callbacks.onOutput
        )
    }

    private func launcherButton(
        _ label: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage).frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }

}

extension LauncherEdge {
    var isVertical: Bool { self == .left || self == .right }

    var displayName: String {
        switch self {
        case .left: "Left"
        case .right: "Right"
        case .top: "Top"
        case .bottom: "Bottom"
        }
    }

    var explanation: String {
        switch self {
        case .left: "Expands to the right, into the screen."
        case .right: "Expands to the left, into the screen."
        case .top: "Expands downward, into the screen."
        case .bottom: "Expands upward, into the screen."
        }
    }
}

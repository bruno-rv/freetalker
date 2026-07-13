import SwiftUI

struct FloatingControlsView: View {
    let state: FloatingControlsHoverState
    let edge: LauncherEdge
    let languagePin: String
    let translationState: TranslationControlsState
    let callbacks: FloatingControlsController.Callbacks

    /// Fixed regardless of `edge` so the collapsed launcher never balloons on the side edges.
    private static let collapsedIconDiameter: CGFloat = 26

    var body: some View {
        Group {
            if state == .collapsed {
                Image(systemName: "waveform")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: Self.collapsedIconDiameter, height: Self.collapsedIconDiameter)
                    .background(Color.accentColor.gradient, in: Circle())
                    .accessibilityLabel("Open FreeTalker controls")
            } else {
                // Always horizontal, even on the left/right edges: a vertical stack forces the
                // text-heavy TranslationControls row to set the panel's width, ballooning it far
                // past the icon column above it.
                HStack(spacing: 4) { controls }
                    .padding(6)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 13))
                    .overlay(RoundedRectangle(cornerRadius: 13).stroke(.tint.opacity(0.45)))
            }
        }
        .padding(3)
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

import AppKit

@MainActor
final class ScratchpadView: NSView {
    let textView: NSTextView
    let editorController: ScratchpadEditorController
    private(set) var formattingButtons: [NSControl] = []

    var onStartDictation: () -> Void = {}
    var onStopDictation: () -> Void = {}
    var onInsertRecovery: () -> Void = {}

    private let previewLabel = NSTextField(wrappingLabelWithString: "")
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let recoveryLabel = NSTextField(wrappingLabelWithString: "")
    private let dictateButton = NSButton(title: "Dictate", target: nil, action: nil)
    private(set) var recoveryButton = NSButton(title: "Insert Recovered Text", target: nil, action: nil)

    var previewText: String? {
        get { previewLabel.isHidden ? nil : previewLabel.stringValue }
        set {
            previewLabel.stringValue = newValue ?? ""
            previewLabel.isHidden = newValue?.isEmpty != false
        }
    }

    var statusText: String? {
        get { statusLabel.isHidden ? nil : statusLabel.stringValue }
        set {
            statusLabel.stringValue = newValue ?? ""
            statusLabel.isHidden = newValue?.isEmpty != false
        }
    }

    var recoveryText: String? {
        get { recoveryLabel.isHidden ? nil : recoveryLabel.stringValue }
        set {
            recoveryLabel.stringValue = newValue ?? ""
            let hidden = newValue?.isEmpty != false
            recoveryLabel.isHidden = hidden
            recoveryButton.isHidden = hidden
        }
    }

    var isRecording = false {
        didSet {
            dictateButton.title = isRecording ? "Stop" : "Dictate"
            dictateButton.setAccessibilityLabel(isRecording ? "Stop scratchpad dictation" : "Start scratchpad dictation")
            let help = isRecording ? "Stop recording and transcribe into the scratchpad" : "Record speech at the current scratchpad selection"
            dictateButton.setAccessibilityHelp(help)
            dictateButton.toolTip = help
        }
    }

    init(document: ScratchpadDocument) {
        textView = RichTextEditor.makeTextView(document: document)
        editorController = ScratchpadEditorController(document: document, textView: textView)
        super.init(frame: .zero)
        build(document: document)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func build(document: ScratchpadDocument) {
        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let heading = NSPopUpButton()
        heading.addItems(withTitles: ["Body", "Heading 1", "Heading 2"])
        heading.target = self
        heading.action = #selector(applyHeading(_:))
        configure(heading, label: "Heading style", help: "Apply a body, heading 1, or heading 2 style to the current paragraph")

        let bold = button("B", label: "Bold", help: "Toggle bold formatting", action: #selector(toggleBold))
        bold.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        let italic = button("I", label: "Italic", help: "Toggle italic formatting", action: #selector(toggleItalic))
        italic.font = NSFontManager.shared.convert(.systemFont(ofSize: NSFont.systemFontSize), toHaveTrait: .italicFontMask)
        let bullets = button("• List", label: "Bulleted list", help: "Toggle a bulleted list", action: #selector(toggleBullets))
        let numbers = button("1. List", label: "Numbered list", help: "Toggle a numbered list", action: #selector(toggleNumbers))
        let clear = button("Clear", label: "Clear formatting", help: "Remove supported formatting without deleting text", action: #selector(clearFormatting))

        dictateButton.target = self
        dictateButton.action = #selector(dictate)
        isRecording = false
        configure(dictateButton, label: "Start scratchpad dictation", help: "Record speech at the current scratchpad selection")

        recoveryButton.target = self
        recoveryButton.action = #selector(insertRecovery)
        recoveryButton.setAccessibilityLabel("Insert recovered transcription")
        recoveryButton.setAccessibilityHelp("Insert the preserved transcription at the current selection")
        recoveryButton.toolTip = "Insert the preserved transcription at the current selection"

        formattingButtons = [heading, bold, italic, bullets, numbers, clear, dictateButton]
        let toolbar = NSStackView(views: formattingButtons)
        toolbar.orientation = .horizontal
        toolbar.spacing = 8
        toolbar.alignment = .centerY

        previewLabel.textColor = .secondaryLabelColor
        previewLabel.font = NSFontManager.shared.convert(
            NSFont.systemFont(ofSize: NSFont.systemFontSize),
            toHaveTrait: .italicFontMask
        )
        previewLabel.setAccessibilityLabel("Live dictation preview")
        statusLabel.textColor = .systemRed
        statusLabel.setAccessibilityLabel("Scratchpad status")
        recoveryLabel.isSelectable = true
        recoveryLabel.setAccessibilityLabel("Recovered transcription")

        previewText = nil
        statusText = document.warning
        recoveryText = nil

        let recoveryRow = NSStackView(views: [recoveryLabel, recoveryButton])
        recoveryRow.orientation = .horizontal
        recoveryRow.spacing = 8
        recoveryRow.distribution = .fill

        let root = NSStackView(views: [toolbar, statusLabel, previewLabel, recoveryRow, scrollView])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 8
        root.translatesAutoresizingMaskIntoConstraints = false
        addSubview(root)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            root.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            root.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            root.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            toolbar.widthAnchor.constraint(equalTo: root.widthAnchor),
            statusLabel.widthAnchor.constraint(equalTo: root.widthAnchor),
            previewLabel.widthAnchor.constraint(equalTo: root.widthAnchor),
            recoveryRow.widthAnchor.constraint(equalTo: root.widthAnchor),
            scrollView.widthAnchor.constraint(equalTo: root.widthAnchor),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 260),
        ])
    }

    private func button(_ title: String, label: String, help: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        configure(button, label: label, help: help)
        return button
    }

    private func configure(_ control: NSControl, label: String, help: String) {
        control.setAccessibilityLabel(label)
        control.setAccessibilityHelp(help)
        control.toolTip = help
    }

    @objc private func applyHeading(_ sender: NSPopUpButton) {
        editorController.applyHeading(ScratchpadHeading(rawValue: sender.indexOfSelectedItem) ?? .body)
    }
    @objc private func toggleBold() { editorController.toggleBold() }
    @objc private func toggleItalic() { editorController.toggleItalic() }
    @objc private func toggleBullets() { editorController.applyList(.bulleted) }
    @objc private func toggleNumbers() { editorController.applyList(.numbered) }
    @objc private func clearFormatting() { editorController.clearFormatting() }
    @objc private func dictate() { isRecording ? onStopDictation() : onStartDictation() }
    @objc private func insertRecovery() { onInsertRecovery() }
}

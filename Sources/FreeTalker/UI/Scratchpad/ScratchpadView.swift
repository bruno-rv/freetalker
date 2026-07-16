import AppKit

@MainActor
final class ScratchpadView: NSView, NSTextFieldDelegate {
    let textView: NSTextView
    let editorController: ScratchpadEditorController
    private(set) var formattingButtons: [NSControl] = []
    private(set) var aiButtons: [NSButton] = []
    private(set) var translateButton = NSPopUpButton(frame: .zero, pullsDown: true)

    var onStartDictation: () -> Void = {}
    var onStopDictation: () -> Void = {}
    var onInsertRecovery: () -> Void = {}
    var onRetryTranslation: () -> Void = {}
    var onInsertSourceText: () -> Void = {}
    var onAIAction: (ScratchpadAIAction) -> Void = { _ in }
    var onCustomAIAction: () -> Void = {}
    var onCustomInstructionChanged: () -> Void = {}

    private let previewLabel = NSTextField(wrappingLabelWithString: "")
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let recoveryLabel = NSTextField(wrappingLabelWithString: "")
    private let translationRecoveryLabel = NSTextField(wrappingLabelWithString: "")
    private let dictateButton = NSButton(title: "Dictate", target: nil, action: nil)
    private(set) var recoveryButton = NSButton(title: "Insert Recovered Text", target: nil, action: nil)
    private(set) var retryTranslationButton = NSButton(title: "Retry translation", target: nil, action: nil)
    private(set) var insertSourceTextButton = NSButton(title: "Insert source text", target: nil, action: nil)
    private let customInstructionField = NSTextField()
    private let aiProgress = NSProgressIndicator()
    private let aiErrorLabel = NSTextField(wrappingLabelWithString: "")
    private let aiPrivacyLabel = NSTextField(wrappingLabelWithString: CloudPrivacyDisclosure.scratchpad)
    private var aiControlDescriptors: [AIControlDescriptor] = []

    /// Pairs a toolbar AI control with the wrapper `updateAIAvailability` annotates and an
    /// explicit `requiresInstruction` flag, so adding a control (e.g. Translate) cannot silently
    /// inherit another control's instruction requirement via index arithmetic.
    private struct AIControlDescriptor {
        let control: NSControl
        let wrapper: NSView
        let requiresInstruction: Bool
    }

    var customInstruction: String {
        get { customInstructionField.stringValue }
        set { customInstructionField.stringValue = newValue }
    }

    var aiPrivacyText: String { aiPrivacyLabel.stringValue }

    var isAIInFlight = false {
        didSet {
            isAIInFlight ? aiProgress.startAnimation(nil) : aiProgress.stopAnimation(nil)
            aiProgress.isHidden = !isAIInFlight
        }
    }

    var aiErrorText: String? {
        get { aiErrorLabel.isHidden ? nil : aiErrorLabel.stringValue }
        set {
            aiErrorLabel.stringValue = newValue ?? ""
            aiErrorLabel.isHidden = newValue?.isEmpty != false
        }
    }

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

    var translationRecovery: TranslationRecoveryPresentation? {
        didSet {
            translationRecoveryLabel.stringValue = translationRecovery.map {
                [$0.message, $0.recoverableText, $0.errorText].compactMap { $0 }.joined(separator: "\n")
            } ?? ""
            let hidden = translationRecovery == nil
            translationRecoveryLabel.isHidden = hidden
            retryTranslationButton.isHidden = hidden
            insertSourceTextButton.isHidden = hidden
            retryTranslationButton.isEnabled = translationRecovery?.actionsEnabled == true
            insertSourceTextButton.isEnabled = translationRecovery?.actionsEnabled == true
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

        retryTranslationButton.target = self
        retryTranslationButton.action = #selector(retryTranslation)
        retryTranslationButton.setAccessibilityHelp("Retry with the current eligible cloud configuration")
        insertSourceTextButton.target = self
        insertSourceTextButton.action = #selector(insertSourceText)
        insertSourceTextButton.setAccessibilityHelp("Insert the retained source at its original destination")

        let improve = aiButton("Improve writing", action: #selector(improveWriting))
        let expand = aiButton("Expand", action: #selector(expandWriting))
        let condense = aiButton("Condense", action: #selector(condenseWriting))
        let custom = aiButton("Custom instruction", action: #selector(customWriting))
        aiButtons = [improve, expand, condense, custom]
        configureTranslateButton()
        customInstructionField.placeholderString = "Custom instruction"
        customInstructionField.delegate = self
        customInstructionField.setAccessibilityLabel("Custom AI instruction")
        customInstructionField.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        aiProgress.style = .spinning
        aiProgress.controlSize = .small
        aiProgress.isHidden = true
        aiErrorLabel.textColor = .systemRed
        aiErrorLabel.setAccessibilityLabel("AI transformation error")
        aiErrorText = nil
        aiPrivacyLabel.textColor = .secondaryLabelColor
        aiPrivacyLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        aiPrivacyLabel.setAccessibilityLabel("Scratchpad AI privacy disclosure")

        let aiWrappers = aiButtons.map { button -> NSView in
            let wrapper = NSStackView(views: [button])
            wrapper.orientation = .horizontal
            return wrapper
        }
        let translateWrapper = NSStackView(views: [translateButton])
        translateWrapper.orientation = .horizontal

        aiControlDescriptors = [
            AIControlDescriptor(control: improve, wrapper: aiWrappers[0], requiresInstruction: false),
            AIControlDescriptor(control: expand, wrapper: aiWrappers[1], requiresInstruction: false),
            AIControlDescriptor(control: condense, wrapper: aiWrappers[2], requiresInstruction: false),
            AIControlDescriptor(control: custom, wrapper: aiWrappers[3], requiresInstruction: true),
            AIControlDescriptor(control: translateButton, wrapper: translateWrapper, requiresInstruction: false),
        ]

        let aiRow = NSStackView(views: aiWrappers + [translateWrapper, customInstructionField, aiProgress])
        aiRow.orientation = .horizontal
        aiRow.spacing = 8
        aiRow.alignment = .centerY

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
        translationRecoveryLabel.isSelectable = true
        translationRecoveryLabel.textColor = .systemRed
        translationRecoveryLabel.setAccessibilityLabel("Translation failed")

        previewText = nil
        statusText = document.warning
        recoveryText = nil
        translationRecovery = nil

        let recoveryRow = NSStackView(views: [recoveryLabel, recoveryButton])
        recoveryRow.orientation = .horizontal
        recoveryRow.spacing = 8
        recoveryRow.distribution = .fill
        let translationRecoveryRow = NSStackView(views: [
            translationRecoveryLabel, retryTranslationButton, insertSourceTextButton
        ])
        translationRecoveryRow.orientation = .horizontal
        translationRecoveryRow.spacing = 8
        translationRecoveryRow.distribution = .fill

        let root = NSStackView(views: [toolbar, aiRow, aiPrivacyLabel, aiErrorLabel, statusLabel, previewLabel, translationRecoveryRow, recoveryRow, scrollView])
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
            aiRow.widthAnchor.constraint(equalTo: root.widthAnchor),
            aiPrivacyLabel.widthAnchor.constraint(equalTo: root.widthAnchor),
            aiErrorLabel.widthAnchor.constraint(equalTo: root.widthAnchor),
            statusLabel.widthAnchor.constraint(equalTo: root.widthAnchor),
            previewLabel.widthAnchor.constraint(equalTo: root.widthAnchor),
            recoveryRow.widthAnchor.constraint(equalTo: root.widthAnchor),
            translationRecoveryRow.widthAnchor.constraint(equalTo: root.widthAnchor),
            scrollView.widthAnchor.constraint(equalTo: root.widthAnchor),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 260),
        ])
    }

    private func button(_ title: String, label: String, help: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        configure(button, label: label, help: help)
        return button
    }

    private func aiButton(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.setAccessibilityLabel(title)
        return button
    }

    private func configureTranslateButton() {
        translateButton.target = self
        translateButton.action = #selector(translateSelected)
        translateButton.addItem(withTitle: "Translate")
        for target in TranslationTarget.allCases {
            translateButton.addItem(withTitle: target.promptName)
        }
        translateButton.setAccessibilityLabel("Translate")
    }

    func updateAIAvailability(snapshot: CloudLLMSettingsSnapshot, hasInput: Bool) {
        for descriptor in aiControlDescriptors {
            let availability = ScratchpadAIAvailability.make(
                eligibility: snapshot.eligibility,
                hasInput: hasInput,
                isInFlight: isAIInFlight,
                hasInstruction: !descriptor.requiresInstruction
                    || !customInstruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                provider: snapshot.provider
            )
            descriptor.control.isEnabled = availability.enabled
            descriptor.control.setAccessibilityHelp(availability.accessibilityHelp)
            descriptor.wrapper.toolTip = availability.tooltip
            descriptor.wrapper.setAccessibilityHelp(availability.accessibilityHelp)
        }
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
    @objc private func retryTranslation() { onRetryTranslation() }
    @objc private func insertSourceText() { onInsertSourceText() }
    @objc private func improveWriting() { onAIAction(.improveWriting) }
    @objc private func expandWriting() { onAIAction(.expand) }
    @objc private func condenseWriting() { onAIAction(.condense) }
    @objc private func customWriting() { onCustomAIAction() }
    @objc private func translateSelected(_ sender: NSPopUpButton) {
        // Item 0 is the fixed "Translate" title (pull-down style never updates it); the real
        // targets start at item 1.
        let itemIndex = sender.indexOfSelectedItem - 1
        guard TranslationTarget.allCases.indices.contains(itemIndex) else { return }
        onAIAction(.translate(TranslationTarget.allCases[itemIndex]))
    }

    func controlTextDidChange(_ notification: Notification) {
        onCustomInstructionChanged()
    }
}

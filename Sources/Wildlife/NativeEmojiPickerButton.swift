import AppKit
import SwiftUI

struct NativeEmojiPickerButton: NSViewRepresentable {
    let emoji: String
    let onSelection: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelection: onSelection)
    }

    func makeNSView(context: Context) -> EmojiPickerControl {
        let control = EmojiPickerControl()
        control.button.target = context.coordinator
        control.button.action = #selector(Coordinator.openPicker(_:))
        control.receiver.onInsert = context.coordinator.receive
        context.coordinator.control = control
        return control
    }

    func updateNSView(_ control: EmojiPickerControl, context: Context) {
        context.coordinator.onSelection = onSelection
        control.emoji = emoji
    }

    @MainActor
    final class Coordinator: NSObject {
        fileprivate weak var control: EmojiPickerControl?
        fileprivate var onSelection: (String) -> Void

        init(onSelection: @escaping (String) -> Void) {
            self.onSelection = onSelection
        }

        @objc fileprivate func openPicker(_ sender: NSButton) {
            guard let control, let window = control.window else { return }
            window.makeFirstResponder(control.receiver)
            NSApplication.shared.orderFrontCharacterPalette(sender)
        }

        fileprivate func receive(_ value: String) {
            onSelection(value)
        }
    }
}

final class EmojiPickerControl: NSView {
    let button = NSButton()
    let receiver = EmojiInsertionReceiver()

    var emoji = "" {
        didSet {
            button.title = emoji
            button.setAccessibilityValue(emoji)
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        receiver.translatesAutoresizingMaskIntoConstraints = false
        receiver.alphaValue = 0.001
        receiver.drawsBackground = false
        receiver.isRichText = false
        receiver.setAccessibilityElement(false)
        addSubview(receiver)

        button.translatesAutoresizingMaskIntoConstraints = false
        button.isBordered = false
        button.font = .systemFont(ofSize: 36)
        button.toolTip = "Change session emoji"
        button.setAccessibilityLabel("Change session emoji")
        addSubview(button)

        NSLayoutConstraint.activate([
            receiver.leadingAnchor.constraint(equalTo: leadingAnchor),
            receiver.trailingAnchor.constraint(equalTo: trailingAnchor),
            receiver.topAnchor.constraint(equalTo: topAnchor),
            receiver.bottomAnchor.constraint(equalTo: bottomAnchor),
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.topAnchor.constraint(equalTo: topAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 52, height: 52)
    }
}

final class EmojiInsertionReceiver: NSTextView {
    var onInsert: (String) -> Void = { _ in }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        let value = (insertString as? NSAttributedString)?.string
            ?? (insertString as? String)
            ?? String(describing: insertString)
        onInsert(value)
    }
}

import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Cross-platform phone entry that formats on every keystroke. On iOS/iPadOS
/// a UITextField is used directly so the display updates live (SwiftUI's
/// TextField with a computed `Binding(get:set:)` can drop mid-keystroke
/// reformats). macOS uses plain SwiftUI `TextField` since AppKit updates live.
struct PhoneInputField: View {
    @Binding var text: String
    let placeholder: String
    /// Pure formatter. Takes raw user input, returns display-formatted text.
    /// Allowed to update bound `PhoneCountry` @State as a side-effect.
    let format: (String) -> String

    var body: some View {
        #if os(iOS)
        PhoneInputFieldUIKit(text: $text, placeholder: placeholder, format: format)
        #else
        TextField(placeholder, text: bridged)
        #endif
    }

    #if !os(iOS)
    private var bridged: Binding<String> {
        Binding(
            get: { text },
            set: { newValue in text = format(newValue) }
        )
    }
    #endif
}

#if os(iOS)

private struct PhoneInputFieldUIKit: UIViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let format: (String) -> String

    func makeUIView(context: Context) -> UITextField {
        let tf = UITextField()
        tf.placeholder = placeholder
        tf.keyboardType = .phonePad
        tf.textContentType = .telephoneNumber
        tf.borderStyle = .none
        tf.delegate = context.coordinator
        tf.text = text
        tf.setContentHuggingPriority(.defaultLow, for: .horizontal)
        tf.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return tf
    }

    func updateUIView(_ tf: UITextField, context: Context) {
        context.coordinator.parent = self
        if tf.placeholder != placeholder { tf.placeholder = placeholder }
        // Sync external updates (prefill, country switch) without clobbering
        // an active edit.
        if tf.text != text {
            tf.text = text
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: PhoneInputFieldUIKit

        init(_ parent: PhoneInputFieldUIKit) { self.parent = parent }

        func textField(
            _ tf: UITextField,
            shouldChangeCharactersIn range: NSRange,
            replacementString string: String
        ) -> Bool {
            let old = (tf.text ?? "") as NSString
            var effRange = range
            let effString = string

            // Backspace through a separator: extend deletion back to include
            // the preceding digit so one press removes one "meaningful" char.
            if effString.isEmpty, effRange.length == 1, effRange.location < old.length {
                let deleted = old.substring(with: effRange)
                if !Self.isDigitOrPlus(deleted), effRange.location > 0 {
                    var loc = effRange.location
                    var len = effRange.length
                    while loc > 0 {
                        let prev = old.substring(with: NSRange(location: loc - 1, length: 1))
                        loc -= 1
                        len += 1
                        if Self.isDigitOrPlus(prev) { break }
                    }
                    effRange = NSRange(location: loc, length: len)
                }
            }

            let proposed = old.replacingCharacters(in: effRange, with: effString) as String

            // Cursor target: count of digits/`+` kept from the prefix plus
            // those just inserted.
            let prefix = old.substring(with: NSRange(location: 0, length: effRange.location))
            let cursorDigits = Self.countDigitsOrPlus(prefix) + Self.countDigitsOrPlus(effString)

            let formatted = parent.format(proposed)

            tf.text = formatted
            if parent.text != formatted {
                parent.text = formatted
            }

            let offset = Self.positionAfter(digits: cursorDigits, in: formatted)
            if let pos = tf.position(from: tf.beginningOfDocument, offset: min(offset, formatted.count)) {
                tf.selectedTextRange = tf.textRange(from: pos, to: pos)
            }
            return false
        }

        private static func isDigitOrPlus(_ s: String) -> Bool {
            guard let ch = s.first else { return false }
            return ch.isNumber || ch == "+"
        }

        private static func countDigitsOrPlus(_ s: String) -> Int {
            var n = 0
            for ch in s where ch.isNumber || ch == "+" { n += 1 }
            return n
        }

        private static func positionAfter(digits target: Int, in s: String) -> Int {
            if target <= 0 { return 0 }
            var seen = 0
            for (i, ch) in s.enumerated() {
                if ch.isNumber || ch == "+" {
                    seen += 1
                    if seen == target { return i + 1 }
                }
            }
            return s.count
        }
    }
}

#endif

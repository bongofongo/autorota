import SwiftUI

/// Standard, user-facing error alert driven by an optional message binding.
///
/// Replaces ad-hoc `.alert("Error", isPresented: .constant(vm.error != nil))`
/// blocks scattered across views. Presents a friendly title, the message, an
/// "OK" dismiss, and an optional "Try Again" action for retryable operations.
/// Clearing the binding (to `nil`) dismisses the alert.
extension View {
    func errorAlert(_ message: Binding<String?>, retry: (() -> Void)? = nil) -> some View {
        modifier(ErrorAlertModifier(message: message, retry: retry))
    }
}

private struct ErrorAlertModifier: ViewModifier {
    @Binding var message: String?
    var retry: (() -> Void)?

    func body(content: Content) -> some View {
        content.alert(
            Text("Something went wrong"),
            isPresented: Binding(
                get: { message != nil },
                set: { presenting in if !presenting { message = nil } }
            ),
            presenting: message
        ) { _ in
            if let retry {
                Button("Try Again") {
                    message = nil
                    retry()
                }
            }
            Button("OK", role: .cancel) { message = nil }
        } message: { msg in
            Text(msg)
        }
    }
}

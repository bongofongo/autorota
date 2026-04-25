#if os(iOS)
import SwiftUI
import MessageUI

/// SwiftUI bridge over `MFMessageComposeViewController`. Pre-fills a single
/// recipient + body and reports the result so the checklist can auto-mark
/// the row as Sent / Cancelled / Failed without polling.
struct MessageComposeView: UIViewControllerRepresentable {

    let recipient: String
    let body: String
    let onResult: (MessageComposeResult) -> Void

    static var canSend: Bool { MFMessageComposeViewController.canSendText() }

    func makeUIViewController(context: Context) -> MFMessageComposeViewController {
        let vc = MFMessageComposeViewController()
        vc.recipients = [recipient]
        vc.body = body
        vc.messageComposeDelegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: MFMessageComposeViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onResult: onResult) }

    final class Coordinator: NSObject, MFMessageComposeViewControllerDelegate {
        let onResult: (MessageComposeResult) -> Void
        init(onResult: @escaping (MessageComposeResult) -> Void) {
            self.onResult = onResult
        }

        func messageComposeViewController(
            _ controller: MFMessageComposeViewController,
            didFinishWith result: MessageComposeResult
        ) {
            controller.dismiss(animated: true) { [onResult] in
                onResult(result)
            }
        }
    }
}
#endif

#if os(iOS)
import SwiftUI
import MessageUI

/// SwiftUI bridge over `MFMessageComposeViewController`. Pre-fills a single
/// recipient + body and reports the result so the checklist can auto-mark
/// the row as Sent / Cancelled / Failed without polling.
struct MessageComposeView: UIViewControllerRepresentable {

    struct Attachment {
        let data: Data
        let typeIdentifier: String
        let filename: String
    }

    let recipient: String
    let body: String
    var attachments: [Attachment] = []
    let onResult: (MessageComposeResult) -> Void

    static var canSend: Bool { MFMessageComposeViewController.canSendText() }
    static var canSendAttachments: Bool { MFMessageComposeViewController.canSendAttachments() }

    func makeUIViewController(context: Context) -> MFMessageComposeViewController {
        let vc = MFMessageComposeViewController()
        vc.recipients = [recipient]
        vc.body = body
        if MFMessageComposeViewController.canSendAttachments() {
            for a in attachments {
                vc.addAttachmentData(a.data, typeIdentifier: a.typeIdentifier, filename: a.filename)
            }
        }
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

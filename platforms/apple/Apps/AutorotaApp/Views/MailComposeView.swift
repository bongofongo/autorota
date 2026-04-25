import SwiftUI
#if canImport(MessageUI)
import MessageUI
#endif
#if canImport(AppKit)
import AppKit
#endif

#if os(iOS)
/// SwiftUI bridge over `MFMailComposeViewController`. Pre-fills recipient,
/// subject, and body and reports the result so the checklist can auto-mark
/// the row.
struct MailComposeView: UIViewControllerRepresentable {

    let recipient: String
    let subject: String
    let body: String
    let onResult: (MFMailComposeResult, Error?) -> Void

    static var canSend: Bool { MFMailComposeViewController.canSendMail() }

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let vc = MFMailComposeViewController()
        vc.setToRecipients([recipient])
        vc.setSubject(subject)
        vc.setMessageBody(body, isHTML: false)
        vc.mailComposeDelegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: MFMailComposeViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onResult: onResult) }

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        let onResult: (MFMailComposeResult, Error?) -> Void
        init(onResult: @escaping (MFMailComposeResult, Error?) -> Void) {
            self.onResult = onResult
        }

        func mailComposeController(
            _ controller: MFMailComposeViewController,
            didFinishWith result: MFMailComposeResult,
            error: Error?
        ) {
            controller.dismiss(animated: true) { [onResult] in
                onResult(result, error)
            }
        }
    }
}
#endif

#if os(macOS)
/// macOS has no in-process mail composer parallel to MFMailCompose. We hand
/// the request off to `NSSharingService` (Mail) and assume success — there's
/// no completion callback for the underlying drafted message either way.
enum MacMailDispatcher {
    static func compose(recipient: String, subject: String, body: String) -> Bool {
        let service = NSSharingService(named: .composeEmail)
        service?.recipients = [recipient]
        service?.subject = subject
        guard let svc = service, svc.canPerform(withItems: [body]) else {
            // Fallback: open mailto: in the user's default handler.
            var comps = URLComponents(string: "mailto:\(recipient)")
            comps?.queryItems = [
                URLQueryItem(name: "subject", value: subject),
                URLQueryItem(name: "body", value: body),
            ]
            if let url = comps?.url {
                NSWorkspace.shared.open(url)
                return true
            }
            return false
        }
        svc.perform(withItems: [body])
        return true
    }
}
#endif

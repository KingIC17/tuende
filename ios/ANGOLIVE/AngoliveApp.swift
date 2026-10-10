import EventKit
import EventKitUI
import SwiftUI
import WebKit

@main
struct AngoliveApp: App {
    var body: some Scene {
        WindowGroup {
            WebAppView()
                .ignoresSafeArea(edges: .bottom)
        }
    }
}

/// Shows the bundled Tuende web app so it works offline; external links open in their own apps.
/// The page asks the app for two native features through window.webkit.messageHandlers:
/// "share" (the iPhone share sheet) and "calendar" (add an agenda event to the Calendar app).
struct WebAppView: UIViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.userContentController.add(context.coordinator, name: "share")
        configuration.userContentController.add(context.coordinator, name: "calendar")

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .systemBackground
        webView.allowsBackForwardNavigationGestures = false
        #if DEBUG
        if #available(iOS 16.4, *) { webView.isInspectable = true }
        #endif
        context.coordinator.webView = webView

        if let page = Bundle.main.url(forResource: "index", withExtension: "html") {
            webView.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, EKEventEditViewDelegate {
        weak var webView: WKWebView?
        private let eventStore = EKEventStore()

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }
            // Embedded content (e.g. the map iframe) loads inside the page; only top-level links leave the app.
            let isSubframe = navigationAction.targetFrame.map { !$0.isMainFrame } ?? false
            if url.isFileURL || url.scheme == "about" || isSubframe {
                decisionHandler(.allow)
            } else {
                UIApplication.shared.open(url)
                decisionHandler(.cancel)
            }
        }

        // Links with target="_blank" and window.open (Maps, WhatsApp, YouTube...).
        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if let url = navigationAction.request.url {
                UIApplication.shared.open(url)
            }
            return nil
        }

        // MARK: Messages from the page

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any] else { return }
            switch message.name {
            case "share": share(body)
            case "calendar": addToCalendar(body)
            default: break
            }
        }

        private func share(_ body: [String: Any]) {
            var items: [Any] = []
            if let text = body["text"] as? String, !text.isEmpty { items.append(text) }
            if let link = body["url"] as? String, let url = URL(string: link) { items.append(url) }
            guard !items.isEmpty else { return }
            let sheet = UIActivityViewController(activityItems: items, applicationActivities: nil)
            present(sheet)
        }

        /// Opens the system "New Event" screen filled in with the agenda event; the person saves or cancels it.
        private func addToCalendar(_ body: [String: Any]) {
            guard let title = body["title"] as? String,
                  let start = Self.date(body["start"] as? String),
                  let end = Self.date(body["end"] as? String) else { return }
            let event = EKEvent(eventStore: eventStore)
            event.title = title
            event.location = body["location"] as? String
            event.notes = body["notes"] as? String
            event.url = (body["url"] as? String).flatMap(URL.init(string:))
            let allDay = body["allDay"] as? Bool ?? false
            event.startDate = start
            // All-day: "end" is the last day itself, but midnight would be read as the end of the day before.
            event.endDate = allDay ? end.addingTimeInterval(12 * 3600) : end
            // An all-day event has no time zone (it is the same days everywhere); setting one switches all-day off.
            if allDay {
                event.isAllDay = true
            } else {
                event.timeZone = TimeZone(identifier: "Africa/Luanda")
            }

            let show = { [weak self] in
                guard let self else { return }
                let editor = EKEventEditViewController()
                editor.eventStore = self.eventStore
                editor.event = event
                editor.editViewDelegate = self
                self.present(editor)
            }
            // From iOS 17 this screen needs no calendar permission; iOS 16 asks the person first.
            if #available(iOS 17.0, *) {
                show()
            } else {
                eventStore.requestAccess(to: .event) { granted, _ in
                    if granted { DispatchQueue.main.async(execute: show) }
                }
            }
        }

        func eventEditViewController(_ controller: EKEventEditViewController, didCompleteWith action: EKEventEditViewAction) {
            controller.dismiss(animated: true)
        }

        private func present(_ controller: UIViewController) {
            guard let webView, var top = webView.window?.rootViewController else { return }
            while let presented = top.presentedViewController { top = presented }
            if let popover = controller.popoverPresentationController {
                popover.sourceView = webView
                popover.sourceRect = CGRect(x: webView.bounds.midX, y: webView.bounds.midY, width: 0, height: 0)
                popover.permittedArrowDirections = []
            }
            top.present(controller, animated: true)
        }

        /// "2026-10-24T18:00:00+01:00" for timed events, "2026-10-24" for all-day ones (read in the phone's
        /// own time zone, so the days stay the same wherever the person is).
        private static func date(_ text: String?) -> Date? {
            guard let text else { return nil }
            if let date = ISO8601DateFormatter().date(from: text) { return date }
            let day = DateFormatter()
            day.calendar = Calendar(identifier: .gregorian)
            day.locale = Locale(identifier: "en_US_POSIX")
            day.timeZone = .current
            day.dateFormat = "yyyy-MM-dd"
            return day.date(from: text)
        }
    }
}

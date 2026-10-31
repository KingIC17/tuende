import CoreLocation
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
/// The page asks the app for native features through window.webkit.messageHandlers:
/// "share" (the iPhone share sheet), "calendar" (add an agenda event to the Calendar app),
/// "location" (the phone's position, so iOS asks once, in the app's own words, instead of a second web prompt
/// that shows the file path), "theme" (the light/dark choice made in the app, so the status bar matches)
/// and "ready" (the first screen is drawn: the page fades in instead of showing half-built).
struct WebAppView: UIViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        let controller = configuration.userContentController
        for name in ["share", "calendar", "location", "theme", "ready"] {
            controller.add(context.coordinator, name: name)
        }
        // navigator.geolocation answered by Core Location (see Coordinator.requestLocation).
        controller.addUserScript(WKUserScript(source: Self.locationShim, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        // Inline scripts have run by the end of the document: tell the app the first screen is ready.
        controller.addUserScript(WKUserScript(
            source: "requestAnimationFrame(function () { window.webkit.messageHandlers.ready.postMessage({}); });",
            injectionTime: .atDocumentEnd, forMainFrameOnly: true))

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .systemBackground
        // Swipe from the left edge goes back, like other iPhone apps (the page's views are history entries).
        webView.allowsBackForwardNavigationGestures = true
        // Hidden until the page says it is ready (or after a few seconds at most).
        webView.alpha = 0
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak webView] in
            guard let webView, webView.alpha == 0 else { return }
            UIView.animate(withDuration: 0.2) { webView.alpha = 1 }
        }
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

    /// Replaces navigator.geolocation with the app's own location (one iOS prompt, with the app's text).
    static let locationShim = """
    (function () {
        var pending = {}, next = 0;
        window.__tuendeLocation = function (id, ok, lat, lng, accuracy, code) {
            var request = pending[id];
            if (!request) return;
            delete pending[id];
            if (ok) {
                request.ok({ coords: { latitude: lat, longitude: lng, accuracy: accuracy, altitude: null, altitudeAccuracy: null, heading: null, speed: null }, timestamp: Date.now() });
            } else if (request.fail) {
                request.fail({ code: code, message: code === 1 ? 'denied' : 'unavailable', PERMISSION_DENIED: 1, POSITION_UNAVAILABLE: 2, TIMEOUT: 3 });
            }
        };
        var geolocation = {
            getCurrentPosition: function (ok, fail) {
                var id = ++next;
                pending[id] = { ok: ok, fail: fail };
                window.webkit.messageHandlers.location.postMessage({ id: id });
            },
            watchPosition: function (ok, fail) { this.getCurrentPosition(ok, fail); return 0; },
            clearWatch: function () {}
        };
        try { Object.defineProperty(navigator, 'geolocation', { value: geolocation, configurable: true }); } catch (e) {}
    })();
    """

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, EKEventEditViewDelegate, CLLocationManagerDelegate {
        weak var webView: WKWebView?
        private let eventStore = EKEventStore()
        private let locationManager = CLLocationManager()
        private var locationRequests: [Int] = []
        private var interfaceStyle: UIUserInterfaceStyle = .unspecified

        // Fallback for the fade-in, and the theme once the web view is in a window.
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            reveal()
            webView.window?.overrideUserInterfaceStyle = interfaceStyle
        }

        private func reveal() {
            guard let webView, webView.alpha == 0 else { return }
            UIView.animate(withDuration: 0.2) { webView.alpha = 1 }
        }

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
            case "location": requestLocation(body)
            case "theme": setTheme(body)
            case "ready": reveal()
            default: break
            }
        }

        // MARK: Theme

        /// "dark" or "light" when chosen in the app, "auto" to follow the iPhone. The window follows, so the status bar
        /// and the page (prefers-color-scheme) always match.
        private func setTheme(_ body: [String: Any]) {
            switch body["theme"] as? String {
            case "dark": interfaceStyle = .dark
            case "light": interfaceStyle = .light
            default: interfaceStyle = .unspecified
            }
            webView?.window?.overrideUserInterfaceStyle = interfaceStyle
        }

        // MARK: Location

        private func requestLocation(_ body: [String: Any]) {
            guard let id = body["id"] as? Int else { return }
            locationRequests.append(id)
            locationManager.delegate = self
            locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
            switch locationManager.authorizationStatus {
            case .notDetermined: locationManager.requestWhenInUseAuthorization()
            case .denied, .restricted: finishLocation(nil, code: 1)
            default: locationManager.requestLocation()
            }
        }

        func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
            guard !locationRequests.isEmpty else { return }
            switch manager.authorizationStatus {
            case .authorizedWhenInUse, .authorizedAlways: manager.requestLocation()
            case .denied, .restricted: finishLocation(nil, code: 1)
            default: break
            }
        }

        func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
            finishLocation(locations.last, code: 2)
        }

        func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
            finishLocation(nil, code: (error as? CLError)?.code == .denied ? 1 : 2)
        }

        /// Answers every waiting request: a position, or code 1 (denied) / 2 (unavailable), as in the web API.
        private func finishLocation(_ location: CLLocation?, code: Int) {
            let ids = locationRequests
            locationRequests = []
            for id in ids {
                let script: String
                if let location {
                    script = "window.__tuendeLocation(\(id), true, \(location.coordinate.latitude), \(location.coordinate.longitude), \(location.horizontalAccuracy), 0)"
                } else {
                    script = "window.__tuendeLocation(\(id), false, 0, 0, 0, \(code))"
                }
                webView?.evaluateJavaScript(script)
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

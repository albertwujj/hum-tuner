import UIKit
@preconcurrency import WebKit

/// Shows the tuner page and connects it to the app's microphone, tone and haptics.
///
/// Page → app (window.webkit.messageHandlers.humNative.postMessage):
///   {cmd: "start"} · {cmd: "stop"} · {cmd: "tone", hz, dur} · {cmd: "tap", i, s}
/// App → page (window.HumNative):
///   started(sampleRate) · failed(reason) · audio(base64Float32) · paused()
final class TunerViewController: UIViewController, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    /// The live page, so web updates reach the app without reinstalling. A copy bundled at build time is
    /// the fallback when offline.
    static let siteURL: URL = {
        #if DEBUG
        // Testing a local copy: launch with -siteURL http://127.0.0.1:8913/index.html
        if let override = UserDefaults.standard.string(forKey: "siteURL"), let url = URL(string: override) { return url }
        #endif
        return URL(string: "https://albertwujj.github.io/hum-tuner/")!
    }()

    private var webView: WKWebView!
    private let audio = AudioController()
    private let haptics = Haptics()
    private var showingBundledCopy = false

    override func loadView() {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.applicationNameForUserAgent = "HumTunerApp/1"
        config.userContentController.add(WeakMessageHandler(self), name: "humNative")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.isOpaque = false
        webView.backgroundColor = .tunerBackground
        webView.scrollView.backgroundColor = .tunerBackground
        // The page lays itself out around the notch and home indicator with env(safe-area-inset-*).
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.allowsLinkPreview = false
        #if DEBUG
        if #available(iOS 16.4, *) { webView.isInspectable = true }
        #endif
        self.webView = webView
        view = webView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        audio.onSamples = { [weak self] base64 in
            self?.call("HumNative.audio('\(base64)')")
        }
        audio.onEvent = { [weak self] event in
            guard let self else { return }
            switch event {
            case .started(let rate):
                UIApplication.shared.isIdleTimerDisabled = true
                haptics.prepare()
                call("HumNative.started(\(rate))")
            case .failed(let reason):
                UIApplication.shared.isIdleTimerDisabled = false
                call("HumNative.failed('\(reason)')")
            case .paused:
                call("HumNative.paused()")
            }
        }
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(appLeftScreen), name: UIApplication.didEnterBackgroundNotification, object: nil)
        center.addObserver(self, selector: #selector(appIsActive), name: UIApplication.didBecomeActiveNotification, object: nil)

        var request = URLRequest(url: Self.siteURL)
        request.timeoutInterval = 10
        webView.load(request)
    }

    @objc private func appLeftScreen() { audio.pause() }
    @objc private func appIsActive() { audio.resumeIfWanted() }

    private func call(_ script: String) {
        webView.evaluateJavaScript("window.HumNative && \(script)", completionHandler: nil)
    }

    // MARK: Messages from the page

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let cmd = body["cmd"] as? String else { return }
        let number = { (key: String, fallback: Double) in (body[key] as? NSNumber)?.doubleValue ?? fallback }
        switch cmd {
        case "start":
            audio.start()
        case "stop":
            audio.stop()
            UIApplication.shared.isIdleTimerDisabled = false
        case "tone":
            audio.playTone(hz: number("hz", 130), duration: number("dur", 1.6))
        case "tap":
            haptics.tap(intensity: Float(number("i", 0.7)), sharpness: Float(number("s", 0.5)))
        default:
            break
        }
    }

    // MARK: Navigation

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        #if DEBUG
        runTestHooks()
        #endif
    }

    #if DEBUG
    private var probeTimer: Timer?

    /// For driving the app from the command line: -autoStart YES presses Start once the page loads;
    /// -probe '<js expression>' prints the expression's value every 2 s.
    private func runTestHooks() {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "autoStart") {
            webView.evaluateJavaScript("document.getElementById('startBtn').click()", completionHandler: nil)
        }
        if let probe = defaults.string(forKey: "probe"), probeTimer == nil {
            probeTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                self?.webView.evaluateJavaScript(probe) { result, error in
                    print("probe:", result.map { "\($0)" } ?? error.map { "\($0)" } ?? "nil")
                    fflush(stdout)
                }
            }
        }
    }
    #endif

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        // A fresh page knows nothing of a running microphone.
        audio.stop()
        UIApplication.shared.isIdleTimerDisabled = false
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let error = error as NSError
        if error.domain == NSURLErrorDomain && error.code != NSURLErrorCancelled { loadBundledCopy() }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        audio.stop()
        webView.reload()
    }

    private func loadBundledCopy() {
        guard !showingBundledCopy,
              let page = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "web") else { return }
        showingBundledCopy = true
        webView.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
    }

    /// Links out of the tuner (the study it cites) open in Safari.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = action.request.url, action.navigationType == .linkActivated,
           url.scheme == "http" || url.scheme == "https", url.host != Self.siteURL.host {
            UIApplication.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url { UIApplication.shared.open(url) }
        return nil
    }
}

/// WKUserContentController holds its handlers strongly; this breaks the cycle with the view controller.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

extension UIColor {
    /// The page's --bg, so nothing flashes while it loads.
    static let tunerBackground = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 14 / 255, green: 18 / 255, blue: 36 / 255, alpha: 1)
            : UIColor(red: 236 / 255, green: 239 / 255, blue: 245 / 255, alpha: 1)
    }
}

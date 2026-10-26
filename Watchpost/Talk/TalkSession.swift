import AVFoundation
import Observation
import UIKit
import WebKit

/// Two-way talk through a camera, using Arlo's WebRTC push-to-talk.
///
/// iOS has no public WebRTC API outside WebKit, so the audio runs in a hidden, non-persistent
/// web view loaded from a bundled page. That page can reach nothing but the WebRTC peer; the
/// microphone is granted only to it and only while a session is open.
@MainActor
@Observable
final class TalkSession {
    enum State: Equatable {
        case idle
        case connecting
        case live
        case failed(String)
    }

    private(set) var state: State = .idle

    @ObservationIgnored private var webView: WKWebView?
    @ObservationIgnored private var bridge: TalkBridge?
    @ObservationIgnored private var listenerId: UUID?
    @ObservationIgnored private var sessionId: String?
    @ObservationIgnored private weak var store: CameraStore?
    @ObservationIgnored private var camera: ArloDevice?
    /// Bumped by every start and stop; a start that was cancelled stops at its next step.
    @ObservationIgnored private var attempt = 0
    /// Candidates found before the offer reaches Arlo wait here, or the camera would drop them.
    @ObservationIgnored private var offerSent = false
    @ObservationIgnored private var queuedCandidates: [String] = []

    func start(camera: ArloDevice, store: CameraStore) async {
        guard state == .idle || isFailed else { return }
        attempt += 1
        let current = attempt
        state = .connecting
        self.store = store
        self.camera = camera
        offerSent = false
        queuedCandidates = []

        let allowed = await AVAudioApplication.requestRecordPermission()
        guard current == attempt else { return }
        guard allowed else {
            state = .failed("Allow microphone access in Settings to talk through cameras.")
            return
        }

        let caps = await store.capabilities(for: camera)
        guard current == attempt else { return }
        if caps.usesSIPTalk {
            state = .failed("This camera uses a newer Arlo talk protocol Ralo doesn't support yet.")
            return
        }

        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth]
            )
            try AVAudioSession.sharedInstance().setActive(true)

            let base = store.base(for: camera)
            await store.events.wake(base: base)
            guard current == attempt else { return }

            let (sessionId, iceServers) = try await store.client.startPushToTalk(camera: camera)
            guard current == attempt else { return }
            self.sessionId = sessionId
            listenerId = store.addListener { [weak self] event in self?.handle(event) }

            let webView = try await makeWebView()
            guard current == attempt else { return }
            let offer = try await webView.callAsyncJavaScript(
                "return await startTalk(iceServers);",
                arguments: ["iceServers": iceServers.map(\.javaScriptValue)],
                contentWorld: .page
            )
            guard current == attempt else { return }
            guard let sdp = offer as? String else { throw ArloError.decoding }

            try await store.client.sendTalkOffer(sdp, sessionId: sessionId, camera: camera, base: base)
            guard current == attempt else { return }
            offerSent = true
            let queued = queuedCandidates
            queuedCandidates = []
            for candidate in queued { send(candidate) }
        } catch {
            guard current == attempt else { return }
            fail(with: error)
        }
    }

    func stop() {
        attempt += 1
        bridge?.cancelLoad()
        if let webView {
            webView.evaluateJavaScript("stopTalk();", completionHandler: nil)
            webView.configuration.userContentController.removeScriptMessageHandler(forName: "talk", contentWorld: .page)
            webView.removeFromSuperview()
        }
        webView = nil
        bridge = nil
        if let listenerId { store?.removeListener(listenerId) }
        listenerId = nil
        sessionId = nil
        offerSent = false
        queuedCandidates = []
        let wasActive = state != .idle
        state = .idle
        if wasActive {
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        }
    }

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    private func fail(with error: Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? "Couldn't start talking to this camera."
        stop()
        state = .failed(message)
    }

    // MARK: Arlo signalling

    private func handle(_ event: ArloEvent) {
        guard let camera, event.resource == camera.cameraResource, event.action == "pushToTalk" else { return }
        let properties = event.properties
        guard let data = properties.string("data") else { return }
        switch properties.string("type") {
        case "answerSdp":
            call("applyAnswer", argument: data)
        case "answerCandidate":
            call("addCandidate", argument: data)
        default:
            break
        }
    }

    fileprivate func received(_ message: [String: Any]) {
        switch message["type"] as? String {
        case "candidate":
            guard let candidate = message["candidate"] as? String else { return }
            if offerSent {
                send(candidate)
            } else {
                queuedCandidates.append(candidate)
            }
        case "state":
            switch message["state"] as? String {
            case "connected": state = .live
            case "failed": fail(with: ArloError.server(message: "The camera didn't answer. Try again."))
            case "closed", "disconnected": if state == .live { stop() }
            default: break
            }
        default:
            break
        }
    }

    private func send(_ candidate: String) {
        guard let store, let camera, let sessionId else { return }
        let base = store.base(for: camera)
        let client = store.client
        Task {
            try? await client.sendTalkCandidate(candidate, sessionId: sessionId, camera: camera, base: base)
        }
    }

    private func call(_ function: String, argument: String) {
        guard let webView else { return }
        Task {
            _ = try? await webView.callAsyncJavaScript(
                "await \(function)(value);", arguments: ["value": argument], contentWorld: .page
            )
        }
    }

    // MARK: Web view

    private func makeWebView() async throws -> WKWebView {
        guard
            let url = Bundle.main.url(forResource: "talk", withExtension: "html"),
            let html = try? String(contentsOf: url, encoding: .utf8)
        else { throw ArloError.unsupported("Talk isn't available in this build.") }

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false

        let bridge = TalkBridge(session: self)
        configuration.userContentController.add(bridge, contentWorld: .page, name: "talk")

        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: configuration)
        webView.uiDelegate = bridge
        webView.navigationDelegate = bridge
        webView.alpha = 0.01
        webView.isUserInteractionEnabled = false
        webView.isAccessibilityElement = false
        webView.accessibilityElementsHidden = true
        // WebKit throttles pages that aren't in a window, which can stop capture.
        Self.keyWindow?.addSubview(webView)
        self.bridge = bridge
        self.webView = webView

        // https://localhost is a secure origin, which WebKit requires for microphone access.
        webView.loadHTMLString(html, baseURL: URL(string: "https://localhost/"))
        try await bridge.waitUntilLoaded()
        return webView
    }

    private static var keyWindow: UIWindow? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
            .flatMap(\.windows)
        return windows.first(where: \.isKeyWindow) ?? windows.first
    }
}

/// Receives messages from the talk page and enforces what it may do.
private final class TalkBridge: NSObject, WKScriptMessageHandler, WKUIDelegate, WKNavigationDelegate {
    weak var session: TalkSession?
    private var loadContinuation: CheckedContinuation<Void, Error>?
    private var loaded = false

    init(session: TalkSession) {
        self.session = session
    }

    @MainActor
    func waitUntilLoaded() async throws {
        if loaded { return }
        try await withCheckedThrowingContinuation { continuation in
            loadContinuation = continuation
        }
    }

    /// Unblocks a start that's still waiting for the page, when talk is stopped mid-load.
    @MainActor
    func cancelLoad() {
        loadContinuation?.resume(throwing: CancellationError())
        loadContinuation = nil
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard
            message.frameInfo.isMainFrame,
            message.frameInfo.securityOrigin.host == "localhost",
            let body = message.body as? [String: Any]
        else { return }
        MainActor.assumeIsolated {
            session?.received(body)
        }
    }

    // Microphone for our own page only; never the camera.
    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        let allowed = origin.host == "localhost" && frame.isMainFrame && type == .microphone
        decisionHandler(allowed ? .grant : .deny)
    }

    // The page may never navigate anywhere.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        let url = navigationAction.request.url
        let isInitialLoad = url?.host == "localhost" && navigationAction.navigationType == .other
        decisionHandler(isInitialLoad && !loaded ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true
        loadContinuation?.resume()
        loadContinuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loadContinuation?.resume(throwing: error)
        loadContinuation = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loadContinuation?.resume(throwing: error)
        loadContinuation = nil
    }
}

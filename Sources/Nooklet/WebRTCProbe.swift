import Foundation
import NookletCore
import WebKit

@MainActor
final class WebRTCProbe: NSObject, WKNavigationDelegate {
    let view: WKWebView = {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        return WKWebView(frame: .zero, configuration: configuration)
    }()
    private var pending: CheckedContinuation<[String], any Error>?
    private var timeout: Task<Void, Never>?

    func collect() async throws -> [String] {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { completion in
                pending = completion
                view.navigationDelegate = self
                view.loadHTMLString("<!doctype html><meta charset=utf-8><title>WebRTC</title>",
                                    baseURL: URL(string: "https://nooklet.invalid/"))
                timeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(13)) }
                    catch { return }
                    self?.finish(.failure(URLError(.timedOut)))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(.failure(CancellationError())) }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { [weak self] in
            guard let self, pending != nil else { return }
            do {
                let value = try await webView.callAsyncJavaScript(Self.script, arguments: [:], in: nil, contentWorld: .page)
                guard let addresses = value as? [String] else { throw URLError(.cannotParseResponse) }
                finish(.success(Set(addresses.compactMap(IPAddresses.normalizedPublic)).sorted()))
            } catch {
                finish(.failure(error))
            }
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        finish(.failure(error))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finish(.failure(URLError(.networkConnectionLost)))
    }

    private func finish(_ result: Result<[String], any Error>) {
        guard let pending else { return }
        self.pending = nil
        timeout?.cancel()
        timeout = nil
        view.navigationDelegate = nil
        view.stopLoading()
        if case .failure = result {
            view.evaluateJavaScript("globalThis.nookletPeer?.close()", completionHandler: nil)
        }
        pending.resume(with: result)
    }

    private static let script = """
        const peer = new RTCPeerConnection({iceServers: [{urls: "stun:stun.cloudflare.com:3478"}]});
        globalThis.nookletPeer = peer;
        peer.createDataChannel("probe");
        const addresses = new Set();
        let timer;
        try {
          const gathering = new Promise(resolve => {
            peer.onicecandidate = event => {
              const candidate = event.candidate;
              if (!candidate) { resolve(); return; }
              if (candidate.type !== "relay") {
                const address = candidate.address || candidate.candidate.split(/\\s+/)[4];
                if (address) addresses.add(address);
              }
            };
            timer = setTimeout(resolve, 8000);
          });
          const offer = await peer.createOffer();
          await peer.setLocalDescription(offer);
          await gathering;
          return Array.from(addresses);
        } finally {
          clearTimeout(timer);
          peer.close();
          delete globalThis.nookletPeer;
        }
        """
}

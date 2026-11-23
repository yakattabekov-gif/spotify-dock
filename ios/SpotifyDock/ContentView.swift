import SwiftUI
import WebKit

struct ContentView: View {
    @EnvironmentObject var model: DockModel
    @State private var manual = ""
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let url = model.webURL {
                DockWebView(url: url).ignoresSafeArea()
            } else {
                panel
            }
        }
    }

    private var panel: some View {
        VStack(spacing: 16) {
            Text("Spotify Dock").font(.system(size: 30, weight: .bold)).foregroundColor(.white)
            ProgressView().progressViewStyle(.circular).tint(.white).scaleEffect(1.3).padding(.top, 8)
            Text(model.status)
                .font(.system(size: 16)).multilineTextAlignment(.center)
                .foregroundColor(.white.opacity(0.67))
            HStack {
                TextField("", text: $manual, prompt: Text("или IP:порт, напр. 192.168.1.5:8766").foregroundColor(.white.opacity(0.35)))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .keyboardType(.URL).submitLabel(.go).focused($focused)
                    .foregroundColor(.white)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.3)))
                    .frame(maxWidth: 320)
                    .onSubmit { go() }
                Button("OK") { go() }.buttonStyle(.borderedProminent).tint(.green)
            }
            .padding(.top, 24)
        }
        .padding(32)
    }

    private func go() { focused = false; model.connectManual(manual) }
}

struct DockWebView: UIViewRepresentable {
    let url: URL
    @EnvironmentObject var model: DockModel

    func makeCoordinator() -> Coordinator { Coordinator(model) }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        // Тот же объект, что и в Android (window.DockApp.rediscover()).
        let js = "window.DockApp = { rediscover: function(){ window.webkit.messageHandlers.dock.postMessage('rediscover'); } };"
        cfg.userContentController.addUserScript(WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        cfg.userContentController.add(context.coordinator, name: "dock")
        let w = WKWebView(frame: .zero, configuration: cfg)
        w.isOpaque = false
        w.backgroundColor = .black
        w.scrollView.backgroundColor = .black
        w.scrollView.bounces = false
        w.scrollView.contentInsetAdjustmentBehavior = .never
        w.navigationDelegate = context.coordinator
        w.load(URLRequest(url: url))
        context.coordinator.loaded = url
        return w
    }

    func updateUIView(_ w: WKWebView, context: Context) {
        if context.coordinator.loaded != url {
            context.coordinator.loaded = url
            w.load(URLRequest(url: url))
        }
    }

    static func dismantleUIView(_ w: WKWebView, coordinator: Coordinator) {
        w.configuration.userContentController.removeScriptMessageHandler(forName: "dock")
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let model: DockModel
        var loaded: URL?
        init(_ m: DockModel) { model = m }

        func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
            if (m.body as? String) == "rediscover" { Task { @MainActor in model.rediscover() } }
        }
        func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) { lost() }
        func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) { lost() }
        private func lost() { Task { @MainActor in model.lost() } }
    }
}

import SwiftUI
import WebKit

// A dev server the agent started, on the phone (#58). The flow the person
// sees: pick (or confirm) the port → one plain sentence about what becomes
// reachable → the page itself, full screen, at real iPhone size. Closing
// the sheet ends the preview on the computer; nothing stays reachable.
//
// Trust: the web view gets a *ticket* the host minted for this one port,
// set as an HttpOnly cookie in a throwaway cookie jar. The device
// credential never enters the web view, and the dev app never sees the
// ticket (the host strips the cookie before forwarding).
struct PreviewSheet: View {
    let agent: AgentSummary
    let client: HostPreviewClient?
    let computerName: String?
    // The terminal's transcript when opened from a terminal: the ports it
    // mentions are offered before the host is asked anything.
    let transcript: String?

    @Environment(\.dismiss) private var dismiss
    @State private var stage: Stage = .choosing
    @State private var candidates: Loadable<PreviewCandidates> = .loading
    @State private var typedPort = ""
    @State private var reloadToken = 0
    @State private var serverListening = true
    @State private var doorStatus: Int?
    @State private var confirmStop = false
    @State private var stopMessage: String?

    private enum Stage: Equatable {
        case choosing
        case consent(PreviewServer)
        case opening(PreviewServer)
        case open(OpenedPreview, PreviewServer)
        case failed(String, PreviewServer?)
    }

    // The project as a folder name; a pane's title is a command line, not a place.
    private var folderName: String {
        let name = (agent.cwd as NSString).lastPathComponent
        return name.isEmpty ? "this folder" : name
    }

    private var mentionedPorts: [Int] {
        transcript.map(LocalhostPortScanner.scan) ?? []
    }

    var body: some View {
        NavigationStack {
            Group {
                switch stage {
                case .choosing:
                    chooser
                case let .consent(server):
                    consent(server)
                case let .opening(server):
                    loadingRow("Opening localhost:\(server.port) on \(computerName ?? "the computer")…")
                case let .open(opened, server):
                    page(opened, server)
                case let .failed(message, server):
                    failure(message, retry: server)
                }
            }
            .background(TaviTheme.canvas)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("preview.done")
                }
                if case let .open(_, server) = stage {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button("Reload", systemImage: "arrow.clockwise") { reloadToken += 1 }
                            Button("Another port", systemImage: "number") { stage = .choosing }
                            Divider()
                            Button("Stop server…", systemImage: "stop.circle", role: .destructive) { confirmStop = true }
                        } label: {
                            Label("More", systemImage: "ellipsis.circle")
                        }
                        .accessibilityIdentifier("preview.menu")
                        .confirmationDialog("Stop the server on localhost:\(server.port)?", isPresented: $confirmStop, titleVisibility: .visible) {
                            Button("Stop server", role: .destructive) { Task { await stopServer(server) } }
                        } message: {
                            Text("The process on \(computerName ?? "the computer") that owns this port is asked to quit. The agent keeps running.")
                        }
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .task { await startup() }
        .onDisappear {
            // The sheet is gone: end the preview on the computer now rather
            // than letting it lapse.
            if case let .open(opened, _) = stage, let client {
                Task { await client.close(id: opened.id) }
            }
        }
        .accessibilityIdentifier("preview.sheet")
    }

    private var title: String {
        switch stage {
        case .choosing, .failed: "Preview"
        case let .consent(server), let .opening(server): server.label
        case let .open(_, server): server.label
        }
    }

    // MARK: - Startup: skip straight to the page when the answer is obvious.

    private func startup() async {
        guard let client else {
            stage = .failed("This computer is not connected right now.", nil)
            return
        }
        // Ask the host what is running here; meanwhile the transcript's
        // ports are already on screen.
        let found = await client.candidates(cwd: agent.cwd)
        switch found {
        case let .value(response):
            candidates = .loaded(response)
            if case .choosing = stage {
                // One running server and no doubt: consent (or open) at once.
                if response.servers.count == 1, let only = response.servers.first {
                    await proceed(to: only)
                } else if response.servers.isEmpty, mentionedPorts.count == 1, let port = mentionedPorts.first {
                    await proceed(to: PreviewServer(port: port))
                }
            }
        case let .refused(_, refusal):
            candidates = .failed(refusal.error)
        case let .failure(message):
            candidates = .failed(message)
        }
    }

    private func proceed(to server: PreviewServer) async {
        if PreviewConsent.given(hostId: agent.hostId, port: server.port) {
            await open(server)
        } else {
            stage = .consent(server)
        }
    }

    // MARK: - Choosing

    private var chooser: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                switch candidates {
                case .loading:
                    loadingRow("Looking for dev servers in \(folderName) on \(computerName ?? "the computer")…")
                        .frame(maxHeight: 80)
                case let .failed(message):
                    messageCard(message, identifier: "preview.candidates.failed")
                case let .loaded(response):
                    if response.available == false, let reason = response.reason {
                        messageCard(reason, identifier: "preview.candidates.unavailable")
                    } else if response.servers.isEmpty {
                        messageCard("Nothing is listening in \(folderName) right now. Start a dev server in the terminal, or type a port below.", identifier: "preview.candidates.empty")
                    } else {
                        section("Running in \(folderName)") {
                            ForEach(response.servers) { server in
                                serverRow(server, detail: [server.command, server.folderName].compactMap { $0 }.joined(separator: " · "))
                            }
                        }
                    }
                }

                let running = Set((candidatesValue?.servers ?? []).map(\.port))
                let mentioned = mentionedPorts.filter { !running.contains($0) }
                if !mentioned.isEmpty {
                    section("Mentioned in the terminal") {
                        ForEach(mentioned, id: \.self) { port in
                            serverRow(PreviewServer(port: port), detail: "the computer confirms it when you open it")
                        }
                    }
                }

                section("Another port") {
                    HStack(spacing: 12) {
                        TextField("5173", text: $typedPort)
                            .keyboardType(.numberPad)
                            .font(.body.monospacedDigit())
                            .textFieldStyle(.plain)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(TaviTheme.well, in: RoundedRectangle(cornerRadius: TaviTheme.wellRadius))
                            .accessibilityIdentifier("preview.port.field")
                        Button("Open") {
                            if let port = Int(typedPort), (1 ... 65_535).contains(port) {
                                Task { await proceed(to: PreviewServer(port: port)) }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(TaviTheme.accent)
                        .foregroundStyle(TaviTheme.accentInk)
                        .disabled(Int(typedPort).map { !(1 ... 65_535).contains($0) } ?? true)
                        .accessibilityIdentifier("preview.port.open")
                    }
                    .padding(12)
                    .taviCard()
                }
            }
            .padding(16)
        }
        .accessibilityIdentifier("preview.chooser")
    }

    private var candidatesValue: PreviewCandidates? {
        if case let .loaded(value) = candidates { return value }
        return nil
    }

    private func section<Content: View>(_ heading: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: heading)
            content()
        }
    }

    private func serverRow(_ server: PreviewServer, detail: String) -> some View {
        Button {
            Task { await proceed(to: server) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "globe")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(TaviTheme.accent)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(server.label)
                        .font(.body.monospaced())
                        .foregroundStyle(TaviTheme.textPrimary)
                    if !detail.isEmpty {
                        Text(detail)
                            .font(.footnote)
                            .foregroundStyle(TaviTheme.textSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(TaviTheme.textSecondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .taviCard()
        .accessibilityIdentifier("preview.server.\(server.port)")
    }

    // MARK: - Consent: one sentence, one tap.

    private func consent(_ server: PreviewServer) -> some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(alignment: .leading, spacing: 14) {
                Image(systemName: "globe")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(TaviTheme.accent)
                Text("Show \(server.label) on this phone?")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(TaviTheme.textPrimary)
                Text(consentSentence(server))
                    .font(.callout)
                    .foregroundStyle(TaviTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    Button("Not now") { stage = .choosing }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("preview.consent.cancel")
                    Button("Open preview") {
                        PreviewConsent.record(hostId: agent.hostId, port: server.port)
                        Task { await open(server) }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(TaviTheme.accent)
                    .foregroundStyle(TaviTheme.accentInk)
                    .accessibilityIdentifier("preview.consent.open")
                }
                .padding(.top, 4)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .taviCard()
            .padding(16)
            Spacer()
            Spacer()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("preview.consent")
    }

    // "The node process in preview-demo on MacBook Air will be viewable from
    // this phone until you close it." — the computer is named only when
    // more than one is paired, like everywhere else on the home.
    private func consentSentence(_ server: PreviewServer) -> String {
        var subject = server.command.map { "The \($0) process" } ?? "The server on \(server.label)"
        if let folder = server.folderName { subject += " in \(folder)" }
        if let computerName { subject += " on \(computerName)" }
        return "\(subject) will be viewable from this phone until you close it. Only this phone can open it, through your tailnet."
    }

    // MARK: - Opening

    private func open(_ server: PreviewServer) async {
        guard let client else { return }
        stage = .opening(server)
        serverListening = true
        doorStatus = nil
        stopMessage = nil
        switch await client.open(cwd: agent.cwd, port: server.port) {
        case let .value(opened):
            stage = .open(opened, server)
        case let .refused(_, refusal):
            stage = .failed(refusal.error, refusal.doorMissing == true ? nil : server)
        case let .failure(message):
            stage = .failed(message, server)
        }
    }

    // MARK: - The page

    private func page(_ opened: OpenedPreview, _ server: PreviewServer) -> some View {
        ZStack(alignment: .bottom) {
            if let client, let url = client.doorURL(port: opened.doorPort) {
                PreviewWebView(
                    url: url,
                    cookie: .init(name: opened.cookieName, value: opened.ticket, domain: client.hostName),
                    reloadToken: reloadToken,
                    onMainDocumentStatus: { doorStatus = $0 }
                )
                .ignoresSafeArea(edges: .bottom)
                .accessibilityIdentifier("preview.web")
            }
            if let banner = pageBanner(server) {
                HStack(spacing: 12) {
                    Text(banner.text)
                        .font(.footnote)
                        .foregroundStyle(TaviTheme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    if banner.offersReopen {
                        Button("Reopen") { Task { await open(server) } }
                            .buttonStyle(.borderedProminent)
                            .tint(TaviTheme.accent)
                            .foregroundStyle(TaviTheme.accentInk)
                            .controlSize(.small)
                            .accessibilityIdentifier("preview.reopen")
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity)
                .background(TaviTheme.card, in: RoundedRectangle(cornerRadius: TaviTheme.cardRadius))
                .overlay(RoundedRectangle(cornerRadius: TaviTheme.cardRadius).stroke(TaviTheme.hairline))
                .padding(12)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("preview.banner")
            }
        }
        .task(id: opened.id) { await heartbeat(opened, server) }
    }

    private func pageBanner(_ server: PreviewServer) -> (text: String, offersReopen: Bool)? {
        if let stopMessage { return (stopMessage, false) }
        if !serverListening { return ("The server on \(server.label) has stopped. Start it again in the terminal, then reopen.", true) }
        if doorStatus == 502 { return ("Nothing is answering on \(server.label) right now.", true) }
        if doorStatus == 401 { return ("This preview ended on the computer. Reopen it to continue.", true) }
        return nil
    }

    // The host keeps a preview alive as long as it hears from this phone;
    // the same call says whether the dev server itself is still there.
    private func heartbeat(_ opened: OpenedPreview, _ server: PreviewServer) async {
        guard let client else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(30))
            if Task.isCancelled { return }
            switch await client.keepAlive(id: opened.id) {
            case let .value(beat):
                serverListening = beat.listening
            case .refused(404, _):
                // The host forgot it (a restart, or it lapsed while the app
                // was away). The page may still be on screen; say so.
                doorStatus = 401
                return
            case .refused, .failure:
                continue
            }
        }
    }

    private func stopServer(_ server: PreviewServer) async {
        guard let client else { return }
        switch await client.stop(cwd: agent.cwd, port: server.port) {
        case let .value(stopped):
            stopMessage = "Asked \(stopped.command) on \(server.label) to quit."
            serverListening = false
        case let .refused(_, refusal):
            stopMessage = refusal.error
        case let .failure(message):
            stopMessage = message
        }
    }

    // MARK: - Failure

    private func failure(_ message: String, retry server: PreviewServer?) -> some View {
        VStack(spacing: 14) {
            messageCard(message, identifier: "preview.failed")
            HStack(spacing: 12) {
                Button("Choose a port") { stage = .choosing }
                    .buttonStyle(.bordered)
                if let server {
                    Button("Try again") { Task { await open(server) } }
                        .buttonStyle(.borderedProminent)
                        .tint(TaviTheme.accent)
                        .foregroundStyle(TaviTheme.accentInk)
                        .accessibilityIdentifier("preview.retry")
                }
            }
            Spacer()
        }
    }

    // MARK: - Bits

    private func loadingRow(_ text: String) -> some View {
        HStack(spacing: 10) {
            ProgressView()
            Text(text)
                .font(.callout)
                .foregroundStyle(TaviTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func messageCard(_ text: String, identifier: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(TaviTheme.textSecondary)
            .multilineTextAlignment(.center)
            .padding(20)
            .frame(maxWidth: .infinity)
            .taviCard()
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .accessibilityIdentifier(identifier)
    }
}

// Consent is asked once per computer and port for as long as the app runs;
// nothing about it is persisted, so a fresh launch asks again.
enum PreviewConsent {
    nonisolated(unsafe) private static var given = Set<String>()

    static func given(hostId: String, port: Int) -> Bool {
        given.contains("\(hostId)|\(port)")
    }

    static func record(hostId: String, port: Int) {
        given.insert("\(hostId)|\(port)")
    }
}

// The web view. A non-persistent data store per preview: its own cookie
// jar (holding only the ticket), no cache or storage shared with anything
// else, gone when the view is.
struct PreviewWebView: UIViewRepresentable {
    struct Cookie: Equatable {
        let name: String
        let value: String
        let domain: String
    }

    let url: URL
    let cookie: Cookie
    let reloadToken: Int
    let onMainDocumentStatus: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onMainDocumentStatus: onMainDocumentStatus) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.allowsInlineMediaPlayback = true
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = true
        view.isOpaque = false
        view.backgroundColor = UIColor(TaviTheme.canvas)
        view.scrollView.backgroundColor = UIColor(TaviTheme.canvas)
        context.coordinator.loadedReloadToken = reloadToken
        let properties: [HTTPCookiePropertyKey: Any] = [
            .name: cookie.name,
            .value: cookie.value,
            .domain: cookie.domain,
            .path: "/",
            .secure: "TRUE",
            HTTPCookiePropertyKey("HttpOnly"): "TRUE",
            .expires: Date().addingTimeInterval(60 * 60 * 24),
        ]
        guard let httpCookie = HTTPCookie(properties: properties) else { return view }
        let request = URLRequest(url: url)
        configuration.websiteDataStore.httpCookieStore.setCookie(httpCookie) {
            view.load(request)
        }
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        if context.coordinator.loadedReloadToken != reloadToken {
            context.coordinator.loadedReloadToken = reloadToken
            view.reload()
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loadedReloadToken = 0
        private let onMainDocumentStatus: (Int) -> Void

        init(onMainDocumentStatus: @escaping (Int) -> Void) {
            self.onMainDocumentStatus = onMainDocumentStatus
        }

        // The door's own answers (401 ended, 502 server gone) render as
        // plain pages; the sheet also hears the status so it can offer
        // Reopen natively.
        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
            if navigationResponse.isForMainFrame, let http = navigationResponse.response as? HTTPURLResponse {
                onMainDocumentStatus(http.statusCode)
            }
            return .allow
        }
    }
}

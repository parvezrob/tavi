import SwiftUI

// Remove a worktree (#81; PRD §7.12, approved canvas "4 · Remove
// worktree"). Names what would be lost — uncommitted changes with their
// +/−, commits not pushed, an agent still in there — and offers the safe
// path first. Discard is spelled out with the counts and is never amber.
// The host repeats the counts back before anything moves.
struct RemoveWorktreeSheet: View {
    let worktree: HomeWorktree
    let client: HostSourceControlClient?
    let computerName: String?
    // Both sheets close and the home refreshes once the worktree is gone.
    let onRemoved: (RemovalReceipt) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var preview: Loadable<RemovalPreview> = .loading
    @State private var working: String?
    @State private var notice: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch preview {
            case .loading:
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Checking \(worktree.info.title) on \(computerName ?? "the computer")…")
                        .font(.callout)
                        .foregroundStyle(TaviTheme.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)
            case let .failed(reason):
                Text("Remove \(worktree.info.title)?")
                    .font(.headline)
                    .foregroundStyle(TaviTheme.textPrimary)
                Text(reason)
                    .font(.subheadline)
                    .foregroundStyle(TaviTheme.textSecondary)
                    .padding(.top, 6)
                    .accessibilityIdentifier("removeWorktree.failed")
                keepButton.padding(.top, 24)
            case let .loaded(preview):
                content(preview)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 28)
        .padding(.bottom, 20)
        .background(TaviTheme.canvas)
        .preferredColorScheme(.dark)
        .task { await load() }
        // No identifier on the container: SwiftUI would stamp it on every
        // child and hide theirs (seen in the #81 capture).
    }

    @ViewBuilder
    private func content(_ preview: RemovalPreview) -> some View {
        Text("Remove \(worktree.info.title)?")
            .font(.headline)
            .foregroundStyle(TaviTheme.textPrimary)
            .accessibilityIdentifier("removeWorktree.title")
        Text(lead(preview))
            .font(.subheadline)
            .foregroundStyle(TaviTheme.textSecondary)
            .padding(.top, 6)

        VStack(alignment: .leading, spacing: 12) {
            if preview.uncommitted.files > 0 {
                line(
                    dot: TaviTheme.accent,
                    text: preview.uncommitted.files == 1 ? "1 uncommitted change" : "\(preview.uncommitted.files) uncommitted changes",
                    trailing: "+\(preview.uncommitted.additions) −\(preview.uncommitted.deletions)",
                    mono: true
                )
            }
            if preview.unpushed.commits > 0 {
                line(
                    dot: TaviTheme.accent,
                    text: preview.unpushed.commits == 1 ? "1 commit not pushed" : "\(preview.unpushed.commits) commits not pushed",
                    trailing: preview.unpushed.upstream == nil ? "no remote branch" : "behind \(preview.unpushed.upstream ?? "")",
                    mono: false
                )
            }
            ForEach(preview.agents, id: \.paneId) { agent in
                line(
                    dot: AgentStatusStyle.of(agent.status).color,
                    text: "\(AgentKindWords.name(agent.kind)) in this worktree is \(AgentStatusStyle.of(agent.status).label.lowercased())",
                    trailing: nil,
                    mono: false
                )
            }
            if preview.isSafe, preview.agents.isEmpty {
                line(dot: TaviTheme.statusDone, text: preview.branchMerged ? "Merged into \(preview.base ?? "its base"); the branch goes too" : "Committed and on \(preview.remote ?? "the remote"); the branch stays", trailing: nil, mono: false)
            }
        }
        .padding(.top, 20)

        VStack(alignment: .leading, spacing: 14) {
            if preview.isMain {
                Text("This is the repository's main checkout. It cannot be removed from here.")
                    .font(.footnote)
                    .foregroundStyle(TaviTheme.textSecondary)
            } else if preview.canPushFirst {
                Button(working == "push" ? "Pushing, then removing…" : "Push branch, then remove") {
                    Task { await remove(preview, pushFirst: true, deleteBranch: nil, label: "push") }
                }
                .buttonStyle(.taviProminent)
                .disabled(working != nil)
                .accessibilityIdentifier("removeWorktree.pushThenRemove")
                discardButton(preview)
            } else if preview.isSafe {
                Button(working == nil ? "Remove" : "Removing…") {
                    Task { await remove(preview, pushFirst: false, deleteBranch: nil, label: "remove") }
                }
                .buttonStyle(.taviProminent)
                .disabled(working != nil)
                .accessibilityIdentifier("removeWorktree.remove")
            } else {
                discardButton(preview)
            }
            keepButton
            if let notice {
                Text(notice)
                    .font(.footnote)
                    .foregroundStyle(TaviTheme.textSecondary)
                    .accessibilityIdentifier("removeWorktree.notice")
            }
        }
        .padding(.top, 28)
    }

    // Plain words in the removed colour, never a filled button: the
    // destructive path must never read as the recommended one.
    private func discardButton(_ preview: RemovalPreview) -> some View {
        Button(working == "discard" ? "Discarding…" : discardLabel(preview)) {
            Task { await remove(preview, pushFirst: false, deleteBranch: preview.unpushed.commits > 0 ? true : nil, label: "discard") }
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(TaviTheme.diffRemoved)
        .disabled(working != nil)
        .padding(.leading, 4)
        .accessibilityIdentifier("removeWorktree.discard")
    }

    private var keepButton: some View {
        Button("Keep it") { dismiss() }
            .font(.subheadline)
            .foregroundStyle(TaviTheme.textSecondary)
            .disabled(working != nil)
            .padding(.leading, 4)
            .accessibilityIdentifier("removeWorktree.keep")
    }

    private func lead(_ preview: RemovalPreview) -> String {
        if preview.isMain { return "This is the repository itself, not a worktree." }
        if !preview.isSafe { return "This worktree has work that exists nowhere else." }
        return preview.agents.isEmpty ? "Everything here is committed and pushed." : "Everything here is committed and pushed; the agent in it will be closed."
    }

    private func discardLabel(_ preview: RemovalPreview) -> String {
        var parts: [String] = []
        if preview.uncommitted.files > 0 { parts.append(preview.uncommitted.files == 1 ? "1 change" : "\(preview.uncommitted.files) changes") }
        if preview.unpushed.commits > 0 { parts.append(preview.unpushed.commits == 1 ? "1 commit" : "\(preview.unpushed.commits) commits") }
        return "Discard \(parts.joined(separator: " and "))"
    }

    private func line(dot: Color, text: String, trailing: String?, mono: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Circle()
                .fill(dot)
                .frame(width: 6, height: 6)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 2 }
            Text(text)
                .font(.subheadline)
                .foregroundStyle(TaviTheme.textPrimary)
            Spacer(minLength: 8)
            if let trailing {
                Text(trailing)
                    .font(mono ? .system(size: 11, design: .monospaced) : .footnote)
                    .foregroundStyle(TaviTheme.textSecondary)
            }
        }
    }

    // MARK: - Actions

    private func load() async {
        guard let client else {
            preview = .failed("Connect a computer first.")
            return
        }
        switch await client.removalPreview(path: worktree.info.path) {
        case let .value(fresh): preview = .loaded(fresh)
        case let .refused(_, reason), let .failure(reason): preview = .failed(reason)
        }
    }

    private func remove(_ confirmed: RemovalPreview, pushFirst: Bool, deleteBranch: Bool?, label: String) async {
        guard let client else { return }
        working = label
        defer { working = nil }
        switch await client.remove(path: worktree.info.path, confirm: confirmed, pushFirst: pushFirst, deleteBranch: deleteBranch) {
        case let .value(receipt):
            onRemoved(receipt)
        case let .refused(_, reason), let .failure(reason):
            notice = reason
            // The counts moved: show the fresh ones before anyone taps again.
            await load()
        }
    }
}

// The agent kind's name as the home shows it, for "Claude Code in this
// worktree is done".
enum AgentKindWords {
    static func name(_ kind: String) -> String {
        switch kind {
        case "claude": "Claude Code"
        case "codex": "Codex"
        case "gemini": "Gemini"
        case "shell": "Terminal"
        default: kind.isEmpty ? "An agent" : kind.prefix(1).uppercased() + kind.dropFirst()
        }
    }
}

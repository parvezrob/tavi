import SwiftUI

// Remove a worktree (#81; PRD §7.12, approved canvas "4 · Remove
// worktree"). Names what would be lost — uncommitted changes with their
// +/−, commits not pushed, an agent still in there — and what happens to
// the branch. Amber only on a path that loses nothing (review of #81: with
// uncommitted changes there is no such path, so there is no amber). Discard
// is spelled out with the counts and never amber. The host repeats the
// counts back before anything moves, and the receipt is shown here before
// the sheets close.
struct RemoveWorktreeSheet: View {
    let worktree: HomeWorktree
    let client: HostSourceControlClient?
    let computerName: String?
    // Called once the person has read the receipt and tapped Done.
    let onRemoved: (RemovalReceipt) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var preview: Loadable<RemovalPreview> = .loading
    @State private var working: String?
    @State private var notice: String?
    @State private var receipt: RemovalReceipt?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let receipt {
                    done(receipt)
                } else {
                    switch preview {
                    case .loading:
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Checking \(worktree.info.title) on \(computerName ?? "the computer")…")
                                .font(.subheadline)
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
                        if let notice, notice != reason {
                            Text(notice)
                                .font(.footnote)
                                .foregroundStyle(TaviTheme.textSecondary)
                                .padding(.top, 12)
                                .accessibilityIdentifier("removeWorktree.notice")
                        }
                        keepButton.padding(.top, 24)
                    case let .loaded(preview):
                        content(preview)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 28)
            .padding(.bottom, 20)
        }
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
        Text(RemovalWords.lead(preview))
            .font(.subheadline)
            .foregroundStyle(TaviTheme.textSecondary)
            .padding(.top, 6)

        VStack(alignment: .leading, spacing: 12) {
            if preview.uncommitted.files > 0 {
                line(
                    dot: TaviTheme.accent,
                    text: RemovalWords.count(preview.uncommitted.files, "uncommitted change"),
                    trailing: "+\(preview.uncommitted.additions) −\(preview.uncommitted.deletions)"
                )
            }
            if preview.unpushed.commits > 0 {
                line(
                    dot: TaviTheme.accent,
                    text: "\(RemovalWords.count(preview.unpushed.commits, "commit")) not pushed",
                    trailing: preview.unpushed.upstream.map { "behind \($0)" } ?? "no remote branch"
                )
            }
            ForEach(preview.agents, id: \.paneId) { agent in
                line(
                    dot: AgentStatusStyle.of(agent.status).color,
                    text: "\(AgentKindWords.name(agent.kind)) in this worktree is \(AgentStatusStyle.of(agent.status).label.lowercased())",
                    trailing: nil
                )
            }
            ForEach(preview.agentsAlsoClosed, id: \.paneId) { agent in
                line(dot: AgentStatusStyle.of(agent.status).color, text: RemovalWords.alsoClosedLine(agent), trailing: nil)
                    .accessibilityIdentifier("removeWorktree.alsoClosed")
            }
            if preview.locked {
                line(dot: TaviTheme.textSecondary, text: "Locked on the computer (Claude Code locks the worktrees it makes); removing unlocks it", trailing: nil)
                    .accessibilityIdentifier("removeWorktree.locked")
            }
            line(dot: TaviTheme.textSecondary, text: RemovalWords.branchLine(preview, afterPush: false), trailing: nil)
                .accessibilityIdentifier("removeWorktree.branch")
        }
        .padding(.top, 20)

        VStack(alignment: .leading, spacing: 14) {
            if preview.isMain {
                Text("This is the repository's main checkout. It cannot be removed from here.")
                    .font(.footnote)
                    .foregroundStyle(TaviTheme.textSecondary)
            } else {
                switch RemovalWords.choice(preview) {
                case .safeRemove:
                    Button(working == nil ? (preview.locked ? "Unlock and remove" : "Remove") : "Removing…") { start("remove") { await remove(preview, pushFirst: false, deleteBranch: nil) } }
                        .buttonStyle(.taviProminent)
                        .disabled(working != nil)
                        .accessibilityIdentifier("removeWorktree.remove")
                case .pushThenRemove:
                    Button(working == "push" ? "Pushing, then removing…" : (preview.locked ? "Push branch, unlock, then remove" : "Push branch, then remove")) { start("push") { await remove(preview, pushFirst: true, deleteBranch: nil) } }
                        .buttonStyle(.taviProminent)
                        .disabled(working != nil)
                        .accessibilityIdentifier("removeWorktree.pushThenRemove")
                    discardButton(preview)
                case .pushAndDiscard:
                    // Uncommitted changes go either way: no amber, both
                    // paths spelled out, and the way to keep them named.
                    Button(working == "push" ? "Pushing, then removing…" : RemovalWords.pushAndDiscardLabel(preview)) { start("push") { await remove(preview, pushFirst: true, deleteBranch: nil) } }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(TaviTheme.diffRemoved)
                        .disabled(working != nil)
                        .padding(.leading, 4)
                        .accessibilityIdentifier("removeWorktree.pushThenRemove")
                    discardButton(preview)
                    Text("To keep the changes, commit them on the Changes tab first.")
                        .font(.footnote)
                        .foregroundStyle(TaviTheme.textSecondary)
                        .padding(.leading, 4)
                case .discardOnly:
                    discardButton(preview)
                }
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

    // What happened, in the host's own words, before anything closes.
    @ViewBuilder
    private func done(_ receipt: RemovalReceipt) -> some View {
        Text("Removed \(worktree.info.title)")
            .font(.headline)
            .foregroundStyle(TaviTheme.textPrimary)
            .accessibilityIdentifier("removeWorktree.done")
        VStack(alignment: .leading, spacing: 12) {
            ForEach(RemovalWords.receiptLines(receipt), id: \.self) { text in
                line(dot: TaviTheme.statusDone, text: text, trailing: nil)
            }
        }
        .padding(.top, 20)
        Button("Done") { dismiss() }
            .buttonStyle(.taviProminent)
            .padding(.top, 28)
            .accessibilityIdentifier("removeWorktree.finish")
    }

    // Plain words in the removed colour, never a filled button: the
    // destructive path must never read as the recommended one.
    private func discardButton(_ preview: RemovalPreview) -> some View {
        Button(working == "discard" ? "Discarding…" : RemovalWords.discardLabel(preview)) {
            start("discard") { await remove(preview, pushFirst: false, deleteBranch: preview.unpushed.commits > 0 ? true : nil) }
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

    private func line(dot: Color, text: String, trailing: String?) -> some View {
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
                    .font(.footnote)
                    .monospacedDigit()
                    .foregroundStyle(TaviTheme.textSecondary)
            }
        }
    }

    // MARK: - Actions

    // The flag flips on the tap itself, so two taps in one frame cannot
    // start two removals (the NewAgentSheet rule).
    private func start(_ label: String, _ action: @escaping () async -> Void) {
        guard working == nil else { return }
        working = label
        Task {
            await action()
            working = nil
        }
    }

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

    private func remove(_ confirmed: RemovalPreview, pushFirst: Bool, deleteBranch: Bool?) async {
        guard let client else { return }
        switch await client.remove(path: worktree.info.path, confirm: confirmed, pushFirst: pushFirst, deleteBranch: deleteBranch) {
        case let .value(receipt):
            self.receipt = receipt
            onRemoved(receipt)
        case let .refused(_, reason), let .failure(reason):
            notice = reason
            // The counts moved: show the fresh ones before anyone taps again.
            await load()
        }
    }
}

// The words the removal sheet chooses, kept as pure functions so the
// choices that lose work are tested (#81 review).
enum RemovalWords {
    enum Choice: Equatable {
        // Nothing here exists only here: one amber Remove.
        case safeRemove
        // Unpushed commits, nothing uncommitted: amber push-then-remove.
        case pushThenRemove
        // Uncommitted changes and unpushed commits: no amber anywhere.
        case pushAndDiscard
        // Uncommitted changes only, or unpushed with no remote.
        case discardOnly
    }

    static func choice(_ preview: RemovalPreview) -> Choice {
        if preview.isSafe { return .safeRemove }
        let canPush = preview.unpushed.commits > 0 && preview.remote != nil && preview.branch != nil
        if canPush { return preview.uncommitted.files == 0 ? .pushThenRemove : .pushAndDiscard }
        return .discardOnly
    }

    static func lead(_ preview: RemovalPreview) -> String {
        if preview.isMain { return "This is the repository itself, not a worktree." }
        if !preview.isSafe { return "This worktree has work that exists nowhere else." }
        return preview.agents.isEmpty ? "Everything here is committed and pushed." : "Everything here is committed and pushed; the agent in it will be closed."
    }

    // Mirrors the host's rule (worktrees.ts removeWorktree): the branch is
    // deleted when merged into its base or when this removal just pushed
    // it (live proof the remote has it); kept otherwise — a stale local
    // remote-tracking ref is not proof (#81 review).
    static func branchWillBeDeleted(_ preview: RemovalPreview, afterPush: Bool) -> Bool {
        if preview.branchMerged { return true }
        return afterPush && preview.unpushed.commits > 0
    }

    static func branchLine(_ preview: RemovalPreview, afterPush: Bool) -> String {
        guard let branch = preview.branch else { return "Not on a branch" }
        if preview.branchMerged { return "\(branch) is merged into \(preview.base ?? "its base") and goes too" }
        if afterPush, preview.unpushed.commits > 0 { return "\(branch) goes here once it is on \(preview.remote ?? "the remote")" }
        if let upstream = preview.unpushed.upstream, preview.unpushed.commits == 0 { return "\(branch) stays here (it is on \(upstream) too)" }
        if preview.unpushed.commits > 0 { return "\(branch) stays here unless you discard its commits" }
        return "\(branch) stays here"
    }

    // herdr closes whole tabs: an agent elsewhere sharing a tab with one in
    // the worktree goes down with it, and the sheet says so by folder.
    static func alsoClosedLine(_ agent: RemovalPreview.Agent) -> String {
        let folder = agent.cwd.map { HomeGrouping.projectName(of: $0) } ?? "another folder"
        return "\(AgentKindWords.name(agent.kind)) in \(folder) shares that tab and closes with it"
    }

    static func discardLabel(_ preview: RemovalPreview) -> String {
        var parts: [String] = []
        if preview.uncommitted.files > 0 { parts.append(count(preview.uncommitted.files, "change")) }
        if preview.unpushed.commits > 0 { parts.append(count(preview.unpushed.commits, "commit")) }
        return parts.isEmpty ? "Discard" : "Discard \(parts.joined(separator: " and "))"
    }

    static func pushAndDiscardLabel(_ preview: RemovalPreview) -> String {
        "Push \(count(preview.unpushed.commits, "commit")), discard \(count(preview.uncommitted.files, "change"))"
    }

    static func receiptLines(_ receipt: RemovalReceipt) -> [String] {
        var lines: [String] = []
        let removed = receipt.removed
        if removed.pushed > 0 { lines.append("Pushed \(count(removed.pushed, "commit")) first") }
        if removed.closedAgents > 0 { lines.append("Closed \(count(removed.closedAgents, "agent")) that was in it".replacingOccurrences(of: "agents that was", with: "agents that were")) }
        if removed.branchDeleted, let branch = removed.branch {
            lines.append("Deleted the branch \(branch)")
        } else if let kept = removed.branchKept {
            lines.append(removed.branchNote ?? "Kept the branch \(kept)")
        }
        if lines.isEmpty { lines.append("The folder is gone") }
        return lines
    }

    static func count(_ number: Int, _ noun: String) -> String {
        "\(number) \(noun)\(number == 1 ? "" : "s")"
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

import PDFKit
import SwiftUI

// Read-only viewer shared by #25 (a diff), #61 (a mentioned file), and #57
// (a browsed one): Markdown rendered, code with line numbers scrolled to
// the `:line` the agent printed, images, PDFs, and one unified diff with
// its lines coloured. Truncation and refusals are said in words. No edit,
// no rename, no delete — the host has no route for them.
struct FileViewerView: View {
    let target: FileTarget
    let client: HostFilesClient?

    @State private var state: Display = .loading

    enum Display {
        case loading
        case text(FileContent)
        case diff(FileDiff)
        case image(Data)
        case pdf(Data)
        case directory(DirectoryListing)
        case refused(String)
        case failed(String)
    }

    var body: some View {
        Group {
            switch state {
            case .loading:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case let .text(content):
                TextFileView(content: content, scrollToLine: target.line)
            case let .diff(diff):
                DiffView(diff: diff)
            case let .image(data):
                ImageFileView(data: data)
            case let .pdf(data):
                PDFFileView(data: data)
            case let .directory(listing):
                List(listing.entries) { entry in
                    Label(entry.name, systemImage: entry.isDirectory ? "folder" : "doc.text")
                        .opacity(entry.ignored ? 0.45 : 1)
                        .listRowBackground(TaviTheme.card)
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            case let .refused(message), let .failed(message):
                VStack {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(TaviTheme.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(20)
                        .frame(maxWidth: .infinity)
                        .taviCard()
                        .accessibilityIdentifier("files.viewer.message")
                    Spacer()
                }
                .padding(TaviTheme.Spacing.screen)
            }
        }
        .background(TaviTheme.canvas)
        .navigationTitle(target.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if let shareable {
                    ShareLink(item: shareable, subject: Text(target.title)) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityIdentifier("files.viewer.share")
                }
            }
        }
        .task(id: target) { await load() }
    }

    private var shareable: String? {
        switch state {
        case let .text(content): content.content
        case let .diff(diff): diff.diff
        default: nil
        }
    }

    private func load() async {
        guard let client else {
            state = .failed("Connect a computer first.")
            return
        }
        switch target.mode {
        case .refusedSecret:
            state = .refused("This file looks like it holds credentials, so Tavi does not show it.")
        case .diff:
            switch await client.diff(cwd: target.cwd, path: target.path) {
            case let .value(diff): state = .diff(diff)
            case let .refused(_, refusal): state = .refused(refusal.error)
            case let .failure(message): state = .failed(message)
            }
        case .directory:
            switch await client.list(cwd: target.cwd, path: target.path) {
            case let .value(listing): state = .directory(listing)
            case let .refused(_, refusal): state = .refused(refusal.error)
            case let .failure(message): state = .failed(message)
            }
        case .content:
            switch await client.content(cwd: target.cwd, path: target.path) {
            case let .value(content):
                state = .text(content)
            case let .refused(status, refusal):
                // Not text: an image or a PDF is fetched raw; anything else
                // is named for what it is, with its size.
                if status == 415, let kind = refusal.preview, kind == .image || kind == .pdf {
                    switch await client.raw(cwd: target.cwd, path: target.path) {
                    case let .value(raw): state = kind == .image ? .image(raw.data) : .pdf(raw.data)
                    case let .refused(_, rawRefusal): state = .refused(rawRefusal.error)
                    case let .failure(message): state = .failed(message)
                    }
                } else if status == 415 {
                    let size = refusal.size.map { " (\(FilesSheet.sizeLabel($0)))" } ?? ""
                    state = .refused("This is a binary file\(size); Tavi shows text, images, and PDFs.")
                } else {
                    state = .refused(refusal.error)
                }
            case let .failure(message):
                state = .failed(message)
            }
        }
    }
}

// Code and prose. Markdown renders as blocks; everything else is
// monospaced with line numbers and, when the agent printed one, scrolled
// to that line. A truncated file says so at the bottom, in words.
private struct TextFileView: View {
    let content: FileContent
    let scrollToLine: Int?

    var body: some View {
        if content.isMarkdown {
            ScrollView {
                MarkdownBlocksView(markdown: content.content)
                    .padding(TaviTheme.Spacing.screen)
                truncationNote
            }
        } else {
            GeometryReader { geometry in
                ScrollViewReader { proxy in
                    ScrollView([.vertical, .horizontal]) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            let lines = content.content.split(separator: "\n", omittingEmptySubsequences: false)
                            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                                HStack(alignment: .top, spacing: 12) {
                                    Text("\(index + 1)")
                                        .frame(width: 40, alignment: .trailing)
                                        .foregroundStyle(TaviTheme.textSecondary.opacity(0.6))
                                    Text(line.isEmpty ? " " : String(line))
                                        .foregroundStyle(TaviTheme.textPrimary)
                                }
                                .font(.system(size: 12, design: .monospaced))
                                .padding(.vertical, 1)
                                .padding(.horizontal, TaviTheme.Spacing.snug)
                                .background(index + 1 == scrollToLine ? TaviTheme.accent.opacity(0.18) : Color.clear)
                                .id(index + 1)
                            }
                            truncationNote
                        }
                        .padding(.vertical, 8)
                        // A two-axis ScrollView centres content shorter than the
                        // screen; a file starts at the top-left corner.
                        .frame(minWidth: geometry.size.width, minHeight: geometry.size.height, alignment: .topLeading)
                    }
                    .onAppear {
                        if let scrollToLine, scrollToLine <= content.lines {
                            proxy.scrollTo(scrollToLine, anchor: .center)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var truncationNote: some View {
        if content.truncated {
            Text("Showing the first \(FilesSheet.sizeLabel(content.content.utf8.count)) of \(FilesSheet.sizeLabel(content.size)).")
                .font(.caption)
                .foregroundStyle(TaviTheme.textSecondary)
                .padding(TaviTheme.Spacing.screen)
        }
    }
}

// Enough Markdown for a plan or a README: headings, paragraphs with inline
// styling, bullet and numbered lists, fenced code, rules. Not a full
// renderer — it shows what agents write, legibly.
struct MarkdownBlocksView: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(Self.blocks(markdown).enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    enum Block: Equatable {
        case heading(level: Int, text: String)
        case paragraph(String)
        case bullet([String])
        case numbered([String])
        case code(String)
        case quote(String)
        case rule
    }

    @ViewBuilder
    private func blockView(_ block: Block) -> some View {
        switch block {
        case let .heading(level, text):
            inline(text)
                .font(level == 1 ? .title2.weight(.bold) : level == 2 ? .title3.weight(.semibold) : .headline)
                .foregroundStyle(TaviTheme.textPrimary)
                .padding(.top, level <= 2 ? 6 : 2)
        case let .paragraph(text):
            inline(text)
                .font(.body)
                .foregroundStyle(TaviTheme.textPrimary)
        case let .bullet(items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(TaviTheme.textSecondary)
                        inline(item).foregroundStyle(TaviTheme.textPrimary)
                    }
                }
            }
            .font(.body)
        case let .numbered(items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(index + 1).").foregroundStyle(TaviTheme.textSecondary).monospacedDigit()
                        inline(item).foregroundStyle(TaviTheme.textPrimary)
                    }
                }
            }
            .font(.body)
        case let .code(text):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(TaviTheme.textPrimary)
                    .padding(TaviTheme.Spacing.snug)
            }
            .background(TaviTheme.well, in: RoundedRectangle(cornerRadius: TaviTheme.wellRadius, style: .continuous))
        case let .quote(text):
            HStack(spacing: 10) {
                Rectangle().fill(TaviTheme.hairline).frame(width: 3)
                inline(text)
                    .font(.body)
                    .foregroundStyle(TaviTheme.textSecondary)
            }
        case .rule:
            Divider().overlay(TaviTheme.hairline)
        }
    }

    private func inline(_ text: String) -> Text {
        if let attributed = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(attributed)
        }
        return Text(text)
    }

    static func blocks(_ markdown: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var bullets: [String] = []
        var numbers: [String] = []
        var code: [String]?
        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))); paragraph = [] }
            if !bullets.isEmpty { blocks.append(.bullet(bullets)); bullets = [] }
            if !numbers.isEmpty { blocks.append(.numbered(numbers)); numbers = [] }
        }
        for rawLine in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if let open = code {
                if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    blocks.append(.code(open.joined(separator: "\n")))
                    code = nil
                } else {
                    code = open + [line]
                }
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") { flush(); code = []; continue }
            if trimmed.isEmpty { flush(); continue }
            if trimmed == "---" || trimmed == "***" || trimmed == "___" { flush(); blocks.append(.rule); continue }
            if trimmed.hasPrefix("#") {
                let level = trimmed.prefix { $0 == "#" }.count
                if level <= 6, trimmed.dropFirst(level).hasPrefix(" ") {
                    flush()
                    blocks.append(.heading(level: level, text: String(trimmed.dropFirst(level + 1))))
                    continue
                }
            }
            if trimmed.hasPrefix("> ") { flush(); blocks.append(.quote(String(trimmed.dropFirst(2)))); continue }
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                if !paragraph.isEmpty || !numbers.isEmpty { flush() }
                bullets.append(String(trimmed.dropFirst(2)))
                continue
            }
            if let dot = trimmed.firstIndex(of: "."), trimmed[..<dot].allSatisfy(\.isNumber), !trimmed[..<dot].isEmpty,
               trimmed[trimmed.index(after: dot)...].hasPrefix(" ") {
                if !paragraph.isEmpty || !bullets.isEmpty { flush() }
                numbers.append(String(trimmed[trimmed.index(dot, offsetBy: 2)...]))
                continue
            }
            if !bullets.isEmpty || !numbers.isEmpty { flush() }
            paragraph.append(trimmed)
        }
        if let open = code { blocks.append(.code(open.joined(separator: "\n"))) }
        flush()
        return blocks
    }
}

// One unified diff, line by line: additions green, deletions in the one
// muted red the theme allows for exactly this, hunk headers quiet.
private struct DiffView: View {
    let diff: FileDiff

    var body: some View {
        if diff.binary {
            Text("Binary file changed.")
                .font(.callout)
                .foregroundStyle(TaviTheme.textSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if diff.diff.isEmpty {
            Text("No textual difference.")
                .font(.callout)
                .foregroundStyle(TaviTheme.textSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            GeometryReader { geometry in
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        let lines = diff.diff.split(separator: "\n", omittingEmptySubsequences: false)
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                            let text = String(line)
                            Text(text.isEmpty ? " " : text)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(Self.color(for: text))
                                .padding(.horizontal, TaviTheme.Spacing.snug)
                                .padding(.vertical, 1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Self.background(for: text))
                        }
                        if diff.truncated {
                            Text("Showing the first 256 KB of this diff.")
                                .font(.caption)
                                .foregroundStyle(TaviTheme.textSecondary)
                                .padding(TaviTheme.Spacing.screen)
                        }
                    }
                    .padding(.vertical, 8)
                    .frame(minWidth: geometry.size.width, minHeight: geometry.size.height, alignment: .topLeading)
                }
            }
            .accessibilityIdentifier("files.viewer.diff")
        }
    }

    private static func color(for line: String) -> Color {
        if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("diff ") || line.hasPrefix("index ") { return TaviTheme.textSecondary }
        if line.hasPrefix("@@") { return TaviTheme.statusWorking }
        if line.hasPrefix("+") { return TaviTheme.statusDone }
        if line.hasPrefix("-") { return TaviTheme.diffRemoved }
        return TaviTheme.textPrimary.opacity(0.85)
    }

    private static func background(for line: String) -> Color {
        if line.hasPrefix("+++") || line.hasPrefix("---") { return .clear }
        if line.hasPrefix("+") { return TaviTheme.statusDone.opacity(0.10) }
        if line.hasPrefix("-") { return TaviTheme.diffRemoved.opacity(0.10) }
        return .clear
    }
}

private struct ImageFileView: View {
    let data: Data

    var body: some View {
        if let image = UIImage(data: data) {
            ScrollView([.vertical, .horizontal]) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
            }
        } else {
            Text("This image could not be decoded.")
                .font(.callout)
                .foregroundStyle(TaviTheme.textSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct PDFFileView: UIViewRepresentable {
    let data: Data

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.backgroundColor = UIColor(TaviTheme.canvas)
        view.document = PDFDocument(data: data)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        if view.document == nil { view.document = PDFDocument(data: data) }
    }
}

import Foundation
import MaxMiCore

/// Dedicated parser for terminal emulators (Warp, Apple Terminal, iTerm2).
///
/// Unlike document/chat apps, a terminal exposes its ENTIRE scrollback as a single
/// AXTextArea blob — no per-command structure, no message rows. The anchored parser
/// learns one prompt shape from the buffer and splits only on lines with that shape.
public struct TerminalParser: SourceParser {
    static let contentCap = 8000
    /// A home-or-absolute path with no prompt terminator inside it.
    static let pathBodyPattern = "(~|/Users/[^/ ]+)(/[^ \t\n:%$#>❯]+)*"
    public init() {}

    public func parseStructured(window: AXNode, app: AppInfo) throws -> CapturedContent? {
        try parse(window, context: ParseContext(app: app))
    }

    public func parse(window: AXNode, app: AppInfo) throws -> ParsedCapture? {
        // One AX walk per capture: the thread key needs the RAW prompt lines, so the blob is read
        // here and the typed session is built from that same blob.
        guard let blob = largestTextArea(in: window), !blob.isEmpty else { return nil }
        let result = Self.sessionResult(fromScrollback: blob, windowTitle: app.windowTitle)
        let session = result.content
        return ParsedCapture(
            sourceApp: app.name,                 // "Warp", "Terminal", "iTerm2"
            sourceKey: terminalKey(app: app, content: blob),
            sourceTitle: app.windowTitle,
            content: ContentRenderer.render(session, style: .full),
            contentKind: .terminal,
            parserVersion: 3,
            accumulationPolicy: .appendItems,
            offscreenPolicy: Self.config.offscreenPolicy,
            structured: session,
            truncated: result.truncated
        )
    }

    /// Terminal scrollback lives in one big AXTextArea. Return the LONGEST text-area value
    /// (Warp = one; some emulators expose a couple — take the richest).
    func largestTextArea(in root: AXNode) -> String? {
        var best: String?
        func walk(_ n: AXNode) {
            if n.role == "AXTextArea", let v = n.value, !v.isEmpty {
                if best == nil || v.count > best!.count { best = v }
            }
            for c in n.children { walk(c) }
        }
        walk(root)
        return best
    }

    /// Option B: group terminal activity by working directory / project, so recall is
    /// "what was I doing in the MaxMi repo?" rather than one giant blob or a thread per command.
    /// Strategy: sniff the deepest cwd-looking path from the scrollback (most recent prompt),
    /// fall back to the window title, fall back to the app name. Heuristic by nature — a
    /// terminal has no structured "current directory" attribute, so we read it from the text.
    func terminalKey(app: AppInfo, content: String) -> String {
        let appSlug = slug(app.name)
        if let dir = workingDirectory(fromContent: content) ?? workingDirectory(fromTitle: app.windowTitle) {
            return "terminal:\(appSlug)/\(dir)"
        }
        // No sniffable cwd (e.g. a full-screen TUI like Claude Code). Separate by the stable window
        // id so distinct windows get distinct threads instead of merging into one "terminal:warp"
        // bucket. We deliberately DON'T key on the window title — TUI titles are volatile (spinners)
        // and would spawn a new thread on every capture. Bare app name only if no window id resolved.
        if let wid = app.windowID {
            return "terminal:\(appSlug)/win-\(wid)"
        }
        return "terminal:\(appSlug)"
    }

    /// Find the LAST (most recent) home-or-absolute path in the scrollback and return its
    /// final component — the project/dir you're currently in. Prompts render cwd as "~/foo/bar"
    /// or "/Users/x/foo/bar"; we take "bar". Returns nil if no prompt cwd is present.
    /// Anchors to the PROMPT (path immediately followed by %/$/❯/#), not any path token in
    /// the buffer — so file arguments (inspect2.mjs) and paths in output (MaxMi.app)) are
    /// rejected; only the shell's current directory is used.
    func workingDirectory(fromContent content: String) -> String? {
        for line in content.split(separator: "\n").reversed() {
            if let dir = promptCwd(in: String(line)) { return dir }
        }
        return nil
    }

    /// Warp/iTerm often put the cwd in the title (e.g. "MaxMi — -zsh" or "~/code/MaxMi").
    /// Titles have no prompt terminator, so match a bare path here.
    func workingDirectory(fromTitle title: String?) -> String? {
        guard let title, !title.isEmpty else { return nil }
        return lastPathComponent(in: title, requirePrompt: false)
    }

    /// A path that is immediately followed (after optional spaces) by a shell prompt
    /// terminator — i.e. the cwd of a prompt line, not a path buried in output.
    private func promptCwd(in s: String) -> String? {
        lastPathComponent(in: s, requirePrompt: true)
    }

    /// Extract the final component of a ~/... or /Users/... path, slugged.
    /// requirePrompt: the path must be followed by a prompt char (%, $, ❯, #, >) — used for
    /// scrollback lines. false for titles (no prompt present).
    private func lastPathComponent(in s: String, requirePrompt: Bool) -> String? {
        let pattern = requirePrompt ? "\(Self.pathBodyPattern)\\s*[%$#>❯]" : Self.pathBodyPattern
        guard let range = s.range(of: pattern, options: .regularExpression) else { return nil }
        var path = String(s[range])
        // Strip the trailing prompt char (and any spaces before it) we matched for anchoring.
        if requirePrompt { path = path.trimmingCharacters(in: CharacterSet(charactersIn: " \t%$#>❯")) }
        guard let last = path.split(separator: "/").last, !last.isEmpty else { return nil }
        let component = String(last)
        // Reject file-looking tokens (a real cwd rarely ends in a known file extension).
        if let dot = component.lastIndex(of: "."), dot != component.startIndex {
            let ext = component[component.index(after: dot)...]
            if ext.count <= 5 && ext.allSatisfy({ $0.isLetter || $0.isNumber }) { return nil }
        }
        return slug(component)
    }

    private func slug(_ s: String) -> String {
        s.lowercased().trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "-")
    }
}

extension TerminalParser: StructuredParser {
    public static let config = ParserConfig(
        app: "Terminal",
        bundleIDs: ParserRegistry.terminalBundleIDs,
        offscreenPolicy: .visibleOnly(maxCharacters: 64_000)
    )

    /// The two prompt shapes worth learning. The trailing `(\s|$)` alternative is what lets an
    /// IDLE prompt (a prompt with nothing typed after it) be recognised, which is how the last
    /// segment learns it is not still running.
    enum PromptShape: Equatable {
        case userHost
        case path

        var pattern: String {
            switch self {
            case .userHost: return "^\\S+@\\S+\\s"
            case .path:     return "^[~/]\\S* [%$❯](\\s|$)"
            }
        }
    }

    /// The shape of the FIRST line that looks like a prompt. Every later split uses that one
    /// shape, so a path printed by a command cannot start a spurious segment.
    static func promptShape(in lines: [String]) -> PromptShape? {
        for line in lines {
            for shape in [PromptShape.userHost, .path]
            where line.range(of: shape.pattern, options: .regularExpression)?.lowerBound
                    == line.startIndex {
                return shape
            }
        }
        return nil
    }

    /// The text the user typed on a prompt line, "" for an idle prompt, nil for an output line.
    static func commandText(in line: String, shape: PromptShape) -> String? {
        guard let head = line.range(of: shape.pattern, options: .regularExpression),
              head.lowerBound == line.startIndex else { return nil }
        var rest = String(line[head.upperBound...])
        // The userHost shape only consumed "user@host "; the cwd and the terminator follow.
        // The path shape already consumed its terminator, so stripping again would eat a
        // prompt character that is part of the command.
        if shape == .userHost,
           let terminator = rest.range(of: "[%$#>❯](\\s|$)", options: .regularExpression) {
            rest = String(rest[terminator.upperBound...])
        }
        return rest.trimmingCharacters(in: .whitespaces)
    }

    static func segments(fromScrollback blob: String) -> [TerminalSegment] {
        let lines = blob.components(separatedBy: "\n")
        guard let shape = promptShape(in: lines) else {
            // Segmentation failure (a full-screen TUI, a pager, an unknown prompt theme).
            return [TerminalSegment(command: nil, output: blob, isRunning: false)]
        }
        var segments: [TerminalSegment] = []
        var preamble: [String] = []
        var open: (command: String, output: [String])?

        func flush(isRunning: Bool) {
            if let open {
                segments.append(TerminalSegment(command: open.command,
                                                output: open.output.joined(separator: "\n"),
                                                isRunning: isRunning))
            } else if !preamble.isEmpty {
                segments.append(TerminalSegment(command: nil,
                                                output: preamble.joined(separator: "\n"),
                                                isRunning: false))
                preamble = []
            }
        }

        for line in lines {
            guard let command = commandText(in: line, shape: shape) else {
                if open != nil { open?.output.append(line) } else { preamble.append(line) }
                continue
            }
            flush(isRunning: false)
            // An idle prompt closes the previous segment and opens nothing.
            open = command.isEmpty ? nil : (command, [])
        }
        // Still open at the end == no trailing prompt == the command has not returned.
        flush(isRunning: open != nil)
        return segments
    }

    /// The full cwd path (not the slug `terminalKey` wants). Title first, because a prompt theme
    /// may render a shortened cwd, then the most recent prompt line.
    static func cwdPath(windowTitle: String?, scrollback: String) -> String? {
        if let windowTitle,
           let range = windowTitle.range(of: pathBodyPattern, options: .regularExpression) {
            return String(windowTitle[range])
        }
        let anchored = "\(pathBodyPattern)\\s*[%$#>❯]"
        for line in scrollback.components(separatedBy: "\n").reversed() {
            guard let range = line.range(of: anchored, options: .regularExpression) else { continue }
            return String(line[range])
                .trimmingCharacters(in: CharacterSet(charactersIn: " \t%$#>❯"))
        }
        return nil
    }

    /// The ONE content path for a terminal. Newest-anchored hard cap on the STRUCTURED value,
    /// because the rendered text is derived from it — capping the string afterwards would just be
    /// undone by the renderer, and it is what keeps `capture.content <= contentCap`.
    static func session(fromScrollback blob: String, windowTitle: String?) -> CapturedContent {
        sessionResult(fromScrollback: blob, windowTitle: windowTitle).content
    }

    /// Keeps the v1 capture's truncation marker aligned with the same structured value that the
    /// v2 parser returns, without a second AX walk or segmentation pass.
    private static func sessionResult(
        fromScrollback blob: String,
        windowTitle: String?
    ) -> (content: CapturedContent, truncated: Bool) {
        let session = TerminalSession(
            cwd: cwdPath(windowTitle: windowTitle, scrollback: blob),
            segments: segments(fromScrollback: blob)
        )
        let unbounded = CapturedContent.terminal(session)
        let content = CaptureAccumulator.bound(unbounded, to: contentCap)
        return (content, content != unbounded)
    }

    public func parse(_ snapshot: AXNode, context: ParseContext) throws -> CapturedContent? {
        let areas = AXQuery.findAll("//AXTextArea", in: snapshot)
        // Warp exposes one; some emulators expose several — take the richest.
        guard let blob = areas.compactMap(\.value).filter({ !$0.isEmpty })
                .max(by: { $0.count < $1.count }) else { return nil }
        return Self.session(fromScrollback: blob, windowTitle: context.windowTitle)
    }
}
